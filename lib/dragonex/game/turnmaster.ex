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

  use Gettext, backend: Dragonex.Gettext
  require Logger

  alias Dragonex.{ExplorationTurns, Games, Intents, TurnMaster, World}
  alias Dragonex.Game.{Beats, Combat, Conversations, Participants, Persistence}
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
    decision = honor_combat_floor(state, decision)
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

  # A main combat turn is already fixed by initiative. Keep consultation for
  # pending human declarations, re-evaluation and explicit mini-turns; those
  # may choose cut_in/react/end_scene. Even there, ordinary main handoffs must
  # obey the same floor rather than letting the model reorder the round.
  def combat_main_handoff(state, world) do
    cond do
      Map.get(state, :combat_handoffs, :initiative) != :initiative or world.phase != :combat ->
        nil

      world.turn_kind == "reaction" or state.tm_reeval or state.pending_mini or
        state.last_was_mini or
          state.interrupted not in [nil, ""] ->
        nil

      Enum.any?(state.intents, fn {name, raw} ->
        Participants.human?(state, name) and Intents.present?(raw) and
            not Intents.stale?(raw, world.phase)
      end) ->
        nil

      true ->
        Combat.next_main_combatant(world)
    end
  end

  def settle_combat_main_handoff(state, name) do
    state = do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
    finish_turnmaster_settle(state)
  end

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

  # Fast path for the D30 forced handoff: after a DM beat in exploration whose
  # last narration unambiguously addresses an eligible human — and no other
  # human's pending intent outranks them — every possible TurnMaster outcome
  # lands on the same `give_turn_to(name)`:
  #
  #   * valid decision (any action)  → `honor_exploration_floor` branch 4
  #     overwrites it to give_turn_to(name);
  #   * invalid action / mute model  → `fallback_world_driven` exploration
  #     branch re-derives the same `addressed_human_after_dm` name;
  #   * provider error (after transient retries) → same fallback branch.
  #
  # The TM beat is pure cost there. The branch order mirrors
  # `honor_exploration_floor` exactly, so the predicate only fires when the
  # handoff is provably forced. Cases where the outcome is NOT forced keep the
  # beat: combat, ambiguous narration (unless D134 already completes an AI
  # cycle), mini/reaction bookkeeping (see below), tm_reeval (a mute TM must
  # park the waiter) and any pending human intent. D134 also honors that
  # pending declaration in exploration's fallback; it still keeps the
  # consultation path rather than treating it as an addressed-name handoff.
  #
  # Mini/reaction guards — `pending_mini` (a cut_in/react turn is parked),
  # `last_was_mini` (the settled beat was a mini turn, even when its actor was
  # the DM: the TM's own judgement must route the return) and `interrupted`
  # (the brief owes the word back to the interrupted actor) all keep the TM
  # beat. Mini/reaction consultation is a conservative requirement (D25/D28),
  # not an equivalence claim.
  #
  # Known divergence (deliberate): the handoff itself is identical, but the
  # error side effects are NOT reproduced — a provider outage that would have
  # failed the TM beat (transient retries, `tm_fallback_streak` increments,
  # `:turnmaster_fallback` system notes, possible TM circuit-breaker pause) is
  # simply skipped here. The forced handoff happens without them.
  #
  # Returns the forced target's name (or nil — hence no `?` suffix).
  def exploration_dm_addressed_human(state, world) do
    last = state.last_actor

    cond do
      world.phase != :exploration -> nil
      state.tm_reeval -> nil
      state.pending_mini or state.last_was_mini or state.interrupted not in [nil, ""] -> nil
      is_nil(last) or last == "" or Participants.pc_actor?(state, last) -> nil
      pending_other_human(state, last) != nil -> nil
      true -> addressed_human_after_dm(state, world)
    end
  end

  # Settle the forced handoff without a TM beat: apply the very decision the
  # floor rules would impose on the TM anyway, then run the standard
  # turnmaster settle bookkeeping (same shape as `settle_exploration_opener`).
  # Check + apply are synchronous inside one `advance` tick, so no off-turn
  # declare can interleave between the predicate and the handoff.
  def settle_exploration_dm_addressed_human(state, name) do
    state = do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
    finish_turnmaster_settle(state)
  end

  # A model may choose different companions for dramatic reasons, but each
  # gets at most one ordinary turn before a manual player can respond. Once
  # all available AI PCs have acted, the human handoff is already forced.
  # A new mixed party also gives its first decision to a person immediately
  # after the DM presents the scene, before any companion beat (D138).
  def exploration_human_due(state, world) do
    if ordinary_exploration_reply?(state, world) and
         pending_other_human(state, state.last_actor) == nil and
         Conversations.target(state, world) == nil do
      context = exploration_context(state, world)
      ExplorationTurns.opening_human(context) || ExplorationTurns.human_due(context)
    end
  end

  def exploration_context(state, world) do
    turns =
      if world.phase == :exploration and
           Enum.any?(state.participants, fn {name, _} ->
             Participants.human?(state, name) and not Participants.ai_pc?(state, name)
           end) do
        Games.recent_turns(state.game_id)
      else
        []
      end

    ExplorationTurns.context(world, state.participants, state.pc_agents, turns)
  end

  defp ordinary_exploration_reply?(state, world) do
    world.phase == :exploration and state.last_actor == "dm" and not state.tm_reeval and
      not state.pending_mini and not state.last_was_mini and state.interrupted in [nil, ""]
  end

  defp honor_exploration_repeat(state, world, decision) do
    to =
      case decision do
        %{action: :give_turn_to, to: to} -> to
        %{action: :pass_to_dm} -> "dm"
        _ -> nil
      end

    name =
      if ordinary_exploration_reply?(state, world) do
        state |> exploration_context(world) |> ExplorationTurns.human_after_repeat(to)
      end

    if name, do: %{action: :give_turn_to, to: name}, else: decision
  end

  def exploration_conversation_target(state, world) do
    case Conversations.target(state, world) do
      nil -> nil
      name -> pending_other_human(state, state.last_actor) || name
    end
  end

  def settle_exploration_conversation(state, name) do
    state = handoff_conversation(state, name)
    finish_turnmaster_settle(state)
  end

  def maybe_handoff_conversation(state, true), do: {state, false}

  def maybe_handoff_conversation(state, false) do
    case exploration_conversation_target(state, Session.read_state(state.session)) do
      nil ->
        {state, false}

      name ->
        {handoff_conversation(state, name), true}
    end
  end

  defp conversation_decision("dm"), do: %{action: :pass_to_dm}
  defp conversation_decision(name), do: %{action: :give_turn_to, to: name}

  defp handoff_conversation(state, name) do
    decision = conversation_decision(name)
    do_apply_decision(state, decision.action, name, decision)
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
              case Conversations.target(state, world) do
                nil ->
                  do_apply_decision(state, :pass_to_dm, "dm", %{action: :pass_to_dm})

                name ->
                  handoff_conversation(state, name)
              end

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
            %{action: :cut_in, to: name}
        end
    end
  end

  defp honor_human_reaction(_state, decision), do: decision

  defp honor_combat_floor(state, %{action: action} = decision)
       when action in [:give_turn_to, :pass_to_dm] do
    world = Session.read_state(state.session)

    if world.phase == :combat do
      mini? = world.turn_kind == "reaction" or state.last_was_mini or state.pending_mini
      next = Combat.next_main_combatant(world, mini?)
      Map.merge(decision, %{action: :give_turn_to, to: next})
    else
      decision
    end
  end

  defp honor_combat_floor(_state, decision), do: decision

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

      (name = Conversations.target(state, world)) != nil ->
        conversation_decision(name)

      is_nil(last) or last == "" or Participants.pc_actor?(state, last) ->
        %{action: :pass_to_dm}

      (name = addressed_human_after_dm(state, world)) != nil ->
        %{action: :give_turn_to, to: name}

      (name = exploration_human_due(state, world)) != nil ->
        %{action: :give_turn_to, to: name}

      true ->
        honor_exploration_repeat(state, world, decision)
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
          tm_nudge:
            dgettext("prompts", "No repitas a %{to}: ya actuó. Elige a otro participante.",
              to: to
            )
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
        state = Combat.start_turn(state, to, "reaction")
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
        state = Combat.start_turn(state, to)
        state = Conversations.returned(state, to)

        %{
          state
          | tm_same_actor_streak: streak,
            tm_fallback_streak: 0,
            interrupted: nil,
            pending_mini: false,
            last_was_mini: false
        }

      {:error, _} ->
        fallback_world_driven(state, :handoff_failed)
    end
  end

  defp handoff_to(state, _, _, _), do: fallback_world_driven(state, :invalid_target)

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

      (name = if(world.phase == :exploration, do: pending_other_human(state, last))) != nil ->
        do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})

      (name = exploration_conversation_target(state, world)) != nil ->
        handoff_conversation(state, name)

      world.phase == :exploration and
          (is_nil(last) or last == "" or Participants.pc_actor?(state, last)) ->
        case pending_other_human(state, last) do
          nil ->
            do_apply_decision(state, :pass_to_dm, "dm", %{action: :pass_to_dm})

          name ->
            do_apply_decision(state, :give_turn_to, name, %{action: :give_turn_to, to: name})
        end

      world.phase == :exploration ->
        human =
          if ordinary_exploration_reply?(state, world) do
            context = exploration_context(state, world)
            ExplorationTurns.opening_human(context) || ExplorationTurns.human_after_ai(context)
          end

        case addressed_human_after_dm(state, world) || human do
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

    # Combat slots and the acted ledger follow every TM handoff. The policy
    # cursor does not, so use it only for exploration's legacy cycle.
    state =
      Combat.fallback_turn(state,
        advance: state.last_actor not in [nil, ""],
        mini: state.last_was_mini
      )

    next = Session.current(state.session) || "dm"

    note =
      case announce do
        :pass ->
          if next == "dm",
            do: dgettext("engine", "El turno pasa al DM."),
            else: dgettext("engine", "El turno pasa a %{next}.", next: next)

        :relevo ->
          case reason do
            :anti_loop -> dgettext("engine", "El motor toma el relevo del turno (anti-bucle).")
            _ -> dgettext("engine", "El motor toma el relevo del turno.")
          end
      end

    {:ok, _} =
      Games.append_event(state.game_id, :system, "system", "all", %{
        note: Dragonex.Text.scrub(note),
        kind: :turnmaster_fallback,
        to: next,
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
            dgettext(
              "engine",
              "⏸ La partida se ha pausado: el TurnMaster falló %{count} veces seguidas. Reanuda manualmente.",
              count: @max_tm_fallback_streak
            )
        })

      %{state | status: :paused, tm_fallback_streak: 0}
    else
      state
    end
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
        note: dgettext("engine", "La intención de %{name} ya no aplica.", name: name)
      })

    %{state | intents: intents}
  end

  # Prepare phase cleanup without writing or publishing. Combat commits the
  # kept intents and these notes together with its private World candidate.
  def prune_stale_intents(state, phase) do
    {kept, dropped} = Intents.drop_stale(state.intents, phase)

    notes =
      dropped
      |> Enum.sort()
      |> Enum.map(&%{note: dgettext("engine", "La intención de %{name} ya no aplica.", name: &1)})

    {%{state | intents: kept}, notes}
  end

  # ------------------------------------------------------------- predicates

  defp addressed_human_after_dm(state, world) do
    humans =
      state.participants
      |> Enum.filter(fn {n, _} ->
        n != "dm" and Participants.human?(state, n) and World.validate_actor(world, n) == :ok
      end)
      |> Enum.map(&elem(&1, 0))

    events = Games.recent_events(state.game_id, 24)

    case last_dm_narration(events) do
      nil ->
        nil

      text ->
        case Dragonex.Text.addressed_pc(text, humans, Map.keys(world.characters)) do
          {:named, name} ->
            name

          :question ->
            last_human_speaker(events, humans) || last_human_turn(state.game_id, humans)

          nil ->
            nil
        end
    end
  end

  defp last_human_turn(game_id, humans) do
    game_id
    |> Games.recent_turns()
    |> Enum.reverse()
    |> Enum.find_value(fn event -> if event.actor in humans, do: event.actor end)
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
