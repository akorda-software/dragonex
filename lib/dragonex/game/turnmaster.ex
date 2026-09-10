defmodule Dragonex.Game.Turnmaster do
  @moduledoc """
  TurnMaster orchestration (D25): applying the handoff agent's decisions
  (`give_turn_to`, `cut_in`, `react`, `pass_to_dm`, `end_scene`) to the Session,
  the exploration floor rules, the anti-loop guards and the deterministic
  WorldDriven fallback when the TurnMaster cannot produce a valid decision.

  Extracted from `Dragonex.Game`. These functions run inside the Game
  GenServer's process and return the mutated state (single-writer, D6): they
  never mutate the World from inside the agent — the Game applies decisions.
  """

  require Logger

  alias Dragonex.{Games, Intents, TurnMaster}
  alias Dragonex.Game.{Beats, Participants, Persistence}
  alias ExAgent.Session

  @tick :advance

  # TurnMaster provider-error circuit (D17/D25): consecutive hard failures of
  # the TurnMaster beat (not "no decision → WorldDriven", which is the normal
  # offline TestModel path). After this many, pause with a system note.
  @max_tm_fallback_streak 4

  # ------------------------------------------------------------- entry points

  def apply_turnmaster_decision(state, nil), do: fallback_world_driven(state, :no_decision)

  def apply_turnmaster_decision(state, %{action: action} = decision) do
    decision = honor_human_reaction(state, decision)
    decision = honor_exploration_floor(state, decision)
    action = decision[:action] || action
    to = decision[:to]

    cond do
      action in [:give_turn_to, :cut_in, :react, :pass_to_dm, :end_scene] ->
        do_apply_decision(state, action, to, decision)

      true ->
        fallback_world_driven(state, :invalid_action)
    end
  end

  def apply_turnmaster_decision(state, _), do: fallback_world_driven(state, :no_decision)

  # After a PC in exploration the world/PNJ answers. Same at opener (no last
  # actor): the DM sits the scene.
  def exploration_opener?(state, world) do
    world.phase == :exploration and is_nil(state.last_actor) and not state.tm_reeval
  end

  def settle_exploration_opener(state) do
    state =
      case pending_other_human(state, nil) do
        nil ->
          do_apply_decision(state, :pass_to_dm, "dm", %{action: :pass_to_dm})

        name ->
          do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
      end

    finish_turnmaster_settle(state)
  end

  # WorldDriven fallback: advance the Session cursor deterministically.
  # `reason` is for logging / the system note; soft reasons (no_decision from
  # TestModel) do NOT trip the TM circuit breaker.
  def tm_next_status(%{status: :paused}), do: :paused
  def tm_next_status(%{status: :waiting}), do: :waiting
  def tm_next_status(_state), do: :running

  # Exploration after a PC: the world answers (D28). Skip the TM beat so a mute
  # model cannot WorldDriven-skip the DM and emit «relevo». Returns
  # {state, skipped_tm?}.
  def maybe_auto_pass_after_pc(state, _current, true), do: {state, false}

  def maybe_auto_pass_after_pc(state, current, false) do
    world = Session.read_state(state.session)

    cond do
      world.phase != :exploration ->
        {state, false}

      not Participants.pc_actor?(state, current) ->
        {state, false}

      true ->
        state =
          case pending_other_human(state, current) do
            nil ->
              do_apply_decision(state, :pass_to_dm, "dm", %{action: :pass_to_dm})

            name ->
              do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
          end

        {state, true}
    end
  end

  # ------------------------------------------------------- decision honoring

  defp honor_human_reaction(state, %{action: action} = decision)
       when action in [:give_turn_to, :pass_to_dm] do
    world = Session.read_state(state.session)

    cond do
      world.phase != :combat ->
        decision

      state.pending_mini ->
        decision

      true ->
        case reaction_human(state, world) do
          nil ->
            decision

          name ->
            if decision[:to] == name, do: decision, else: %{action: :cut_in, to: name}
        end
    end
  end

  defp honor_human_reaction(_state, decision), do: decision

  # After a PC in exploration the world/PNJ answers. Same at opener (no last
  # actor): the DM sits the scene. Honor even when the model gives the next PC
  # or stays mute — never «relevo» in exploration.
  defp honor_exploration_floor(state, decision) do
    world = Session.read_state(state.session)
    last = state.last_actor

    cond do
      world.phase != :exploration ->
        decision

      (name = pending_other_human(state, last)) != nil ->
        %{action: :give_turn_to, to: name}

      is_nil(last) or last == "" or Participants.pc_actor?(state, last) ->
        %{action: :pass_to_dm}

      (name = addressed_human_after_dm(state)) != nil ->
        %{action: :give_turn_to, to: name}

      true ->
        decision
    end
  end

  # ------------------------------------------------------------ application

  defp do_apply_decision(state, action, to, decision) do
    # Anti-loop: same actor twice in a row via give_turn_to (not cut_in/react).
    same_give? =
      action == :give_turn_to and is_binary(to) and to == state.last_actor and
        not state.last_was_mini

    repeat_cut? =
      action in [:cut_in, :react] and is_binary(to) and to == state.last_actor

    streak = if same_give?, do: state.tm_same_actor_streak + 1, else: 0

    if repeat_cut? or streak >= 2 do
      Logger.info(
        "dragonex game #{state.game_id} turnmaster anti-loop: #{to} repeated; WorldDriven fallback"
      )

      state = %{
        state
        | tm_same_actor_streak: 0,
          tm_nudge: "No repitas a #{to}: ya actuó. Elige a otro participante."
      }

      fallback_world_driven(state, :anti_loop)
    else
      case action do
        :end_scene ->
          apply_end_scene(state)

        :pass_to_dm ->
          handoff_to(state, "dm", decision, streak)

        :cut_in ->
          apply_mini_handoff(state, to, decision, streak)

        :react ->
          apply_mini_handoff(state, to, decision, streak)

        :give_turn_to ->
          handoff_to(state, to, decision, streak)
      end
    end
  end

  defp apply_mini_handoff(state, to, decision, streak) when is_binary(to) do
    # Remember who held the floor so the next TM brief can return the word.
    interrupted = Session.current(state.session) || state.last_actor
    state = %{state | interrupted: interrupted, tm_same_actor_streak: streak}
    target = resolve_participant(state, to)

    case Session.handoff(state.session, target) do
      {:ok, _} ->
        append_tm_note(state, decision)
        state = put_current_combatant(state, to)
        %{state | pending_mini: true, tm_fallback_streak: 0}

      {:error, _} ->
        fallback_world_driven(state, :handoff_failed)
    end
  end

  defp apply_mini_handoff(state, _, _, _), do: fallback_world_driven(state, :invalid_target)

  defp handoff_to(state, to, decision, streak) when is_binary(to) do
    target = resolve_participant(state, to)

    case Session.handoff(state.session, target) do
      {:ok, _} ->
        append_tm_note(state, decision)
        state = put_current_combatant(state, to)

        %{
          state
          | tm_same_actor_streak: streak,
            tm_fallback_streak: 0,
            interrupted: nil,
            pending_mini: false
        }

      {:error, _} ->
        fallback_world_driven(state, :handoff_failed)
    end
  end

  defp handoff_to(state, _, _, _), do: fallback_world_driven(state, :invalid_target)

  defp put_current_combatant(state, to) do
    world = Session.read_state(state.session)
    name = Dragonex.World.resolve_combatant(world, to)
    proposer = Session.current(state.session) || "dm"

    case Session.update_state(state.session, proposer, Dragonex.World.set_current_combatant(name)) do
      {:ok, _} -> state
      {:error, _} -> state
    end
  end

  # Session participants are "dm" + PC names. Monsters still resolve to the DM
  # as controller (D34); the live slot is `World.current_combatant`.
  defp resolve_participant(_state, name) when name == "dm", do: "dm"

  defp resolve_participant(state, name) do
    cond do
      Map.has_key?(state.participants, name) ->
        name

      true ->
        world = Session.read_state(state.session)
        Dragonex.World.controller_of(world, name)
    end
  end

  defp apply_end_scene(state) do
    world = Session.read_state(state.session)

    if world.phase == :combat do
      proposer = Session.current(state.session) || "dm"

      _ =
        Session.update_state(state.session, proposer, Dragonex.World.end_combat())
    end

    case Session.handoff(state.session, "dm") do
      {:ok, _} ->
        append_tm_note(state, %{action: :end_scene, to: "dm"})

        %{
          state
          | tm_same_actor_streak: 0,
            tm_fallback_streak: 0,
            interrupted: nil,
            pending_mini: false
        }

      {:error, _} ->
        fallback_world_driven(state, :handoff_failed)
    end
  end

  defp append_tm_note(state, decision) do
    note =
      decision
      |> TurnMaster.decision_note()
      |> Dragonex.Text.scrub()

    payload = %{
      note: note,
      kind: decision[:action],
      to: decision[:to]
    }

    {:ok, _} = Games.append_event(state.game_id, :system, "turnmaster", "all", payload)
    :ok
  end

  defp finish_turnmaster_settle(state) do
    next_status = tm_next_status(state)
    state = %{state | loop_phase: :actor, tm_nudge: nil, tm_reeval: false}
    Persistence.persist(state, next_status)
    Persistence.broadcast_updated(state)
    if next_status == :running, do: send(self(), @tick)
    %{state | status: next_status}
  end

  # ------------------------------------------------------------ WorldDriven

  def fallback_world_driven(%{tm_reeval: true} = state, _reason) do
    # Re-eval from :waiting: keep the current waiter. WorldDriven would
    # end_turn them and steal the floor they were already holding.
    # If they declared while the TM beat was in flight, consume now.
    state = %{
      state
      | tm_reeval: false,
        tm_same_actor_streak: 0,
        pending_mini: false
    }

    park_or_consume_waiter(state)
  end

  def fallback_world_driven(state, reason) do
    world = Session.read_state(state.session)
    last = state.last_actor

    cond do
      # Anti-recursion: the branches below re-enter do_apply_decision, whose
      # handoff failure calls back here with :handoff_failed. Re-entering the
      # decision path would loop forever (the exploration branches bypass the
      # tm_fallback_streak breaker); route to the cycle instead, which counts
      # the hard failure and trips the circuit after @max_tm_fallback_streak.
      reason == :handoff_failed ->
        fallback_world_driven_cycle(state, reason, :pass)

      world.phase == :exploration and
          (is_nil(last) or last == "" or Participants.pc_actor?(state, last)) ->
        case pending_other_human(state, last) do
          nil ->
            do_apply_decision(state, :pass_to_dm, "dm", %{action: :pass_to_dm})

          name ->
            do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
        end

      world.phase == :exploration ->
        case addressed_human_after_dm(state) do
          nil ->
            fallback_world_driven_cycle(state, reason, :pass)

          name ->
            do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
        end

      true ->
        fallback_world_driven_cycle(state, reason, :relevo)
    end
  end

  defp fallback_world_driven_cycle(state, reason, announce) do
    hard? = reason in [:tm_error, :handoff_failed]
    streak = if hard?, do: state.tm_fallback_streak + 1, else: state.tm_fallback_streak

    current = Session.current(state.session)

    # Prefer end_turn when we still sit on the actor who just finished — that
    # advances WorldDriven past them. At partida start (nobody has acted yet)
    # keep the policy's current so we don't skip the opener.
    _ =
      cond do
        is_nil(state.last_actor) and is_binary(current) and current != "" ->
          :ok

        is_binary(current) and current != "" ->
          case Session.end_turn(state.session, current) do
            {:ok, _} -> :ok
            {:error, _} -> try_handoff_first(state)
          end

        true ->
          try_handoff_first(state)
      end

    next = Session.current(state.session) || "dm"
    state = put_current_combatant(state, next)

    note =
      case announce do
        :pass ->
          if next == "dm", do: "El turno pasa al DM.", else: "El turno pasa a #{next}."

        :relevo ->
          case reason do
            :anti_loop -> "El motor toma el relevo del turno (anti-bucle)."
            _ -> "El motor toma el relevo del turno."
          end
      end

    {:ok, _} =
      Games.append_event(state.game_id, :system, "system", "all", %{
        note: Dragonex.Text.scrub(note),
        kind: :turnmaster_fallback,
        reason: reason
      })

    state = %{
      state
      | tm_fallback_streak: streak,
        tm_same_actor_streak: 0,
        pending_mini: false
    }

    if hard? and streak >= @max_tm_fallback_streak do
      Logger.warning(
        "dragonex game #{state.game_id} pausing after #{streak} consecutive TurnMaster failures"
      )

      {:ok, _} =
        Games.append_event(state.game_id, :system, "system", "all", %{
          note:
            "⏸ La partida se ha pausado: el TurnMaster falló #{@max_tm_fallback_streak} veces seguidas. Reanuda manualmente."
        })

      %{state | status: :paused, tm_fallback_streak: 0}
    else
      state
    end
  end

  defp try_handoff_first(state) do
    # Session.start already ran; ask policy for next via a dummy end if needed.
    # Last resort: hand off to dm.
    _ = Session.handoff(state.session, "dm")
    :ok
  end

  # --------------------------------------------------------- waiter parking

  defp park_or_consume_waiter(state) do
    current = Session.current(state.session)
    world = Session.read_state(state.session)

    case take_ready_intent(state, current, world) do
      {:ready, state} ->
        turn_id = Beats.generate_turn_id()
        Beats.append_turn_marker(state.game_id, current, turn_id, world)
        Beats.consume_intent(state, current, turn_id, world)

      {:none, state} ->
        %{state | status: :waiting}
    end
  end

  def take_ready_intent(state, name, world) do
    raw = Map.get(state.intents, name)

    cond do
      not Intents.present?(raw) ->
        {:none, state}

      Intents.stale?(raw, world.phase) ->
        {:none, discard_intent(state, name)}

      true ->
        {:ready, state}
    end
  end

  defp discard_intent(state, name) do
    intents = Map.delete(state.intents, name)
    Games.save_intents(state.game_id, intents)

    {:ok, _} =
      Games.append_event(state.game_id, :system, "system", "all", %{
        note: "La intención de #{name} ya no aplica."
      })

    %{state | intents: intents}
  end

  # Dropped intents when the phase changes (e.g. combat → exploration): the
  # declared plan no longer applies. Called by `Game.Combat` after ending a
  # combat, still inside the Game process.
  def prune_stale_intents(state) do
    world = Session.read_state(state.session)
    {kept, dropped} = Intents.drop_stale(state.intents, world.phase)

    case dropped do
      [] ->
        state

      names ->
        Enum.each(names, fn name ->
          {:ok, _} =
            Games.append_event(state.game_id, :system, "system", "all", %{
              note: "La intención de #{name} ya no aplica."
            })
        end)

        Games.save_intents(state.game_id, kept)
        %{state | intents: kept}
    end
  end

  # ------------------------------------------------------------- predicates

  defp addressed_human_after_dm(state) do
    humans =
      state.participants
      |> Enum.filter(fn {n, _} -> n != "dm" and Participants.human?(state, n) end)
      |> Enum.map(&elem(&1, 0))

    events = Games.recent_events(state.game_id, 24)

    case last_dm_narration(events) do
      nil ->
        nil

      text ->
        case Dragonex.Text.addressed_pc(text, humans) do
          {:named, name} -> name
          :question -> last_human_speaker(events, humans)
          nil -> nil
        end
    end
  end

  defp last_dm_narration(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: :narration, actor: "dm", payload: p} ->
        case String.trim(p["text"] || p[:text] || "") do
          "" -> nil
          t -> t
        end

      _ ->
        nil
    end)
  end

  defp last_human_speaker(events, humans) do
    set = MapSet.new(humans)

    events
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.type != :narration or &1.actor != "dm"))
    |> Enum.drop(1)
    |> Enum.find_value(fn
      %{type: t, actor: a} when t in [:action, :narration] ->
        if MapSet.member?(set, a), do: a

      _ ->
        nil
    end)
  end

  def pending_other_human(state, current) do
    Enum.find_value(state.intents, fn {name, raw} ->
      n = to_string(name)

      if n != current and Participants.human?(state, n) and Intents.present?(raw) and
           not Intents.stale?(raw, :exploration) do
        n
      end
    end)
  end

  defp reaction_human(state, world) do
    Enum.find_value(state.intents, fn {name, raw} ->
      if Participants.human?(state, name) and Intents.reaction?(raw) and
           not Intents.stale?(raw, world.phase) do
        to_string(name)
      end
    end)
  end
end
