defmodule Dragonex.Game.Combat do
  @moduledoc """
  Engine-driven combat bookkeeping: ending combat when it's over, forcing
  initiative when a beat spawns hostiles without rolling it, marking actors as
  acted and advancing the round.

  Extracted from `Dragonex.Game`. These functions run inside the Game
  GenServer's process and return the mutated state (single-writer, D6) — the
  engine, not the DM, owns these transitions.
  """

  use Gettext, backend: Dragonex.Gettext
  require Logger

  alias Dragonex.{Games, RollLog, World}
  alias Dragonex.Game.{Persistence, Turnmaster}
  alias ExAgent.Session

  @doc "Recover a settled combat roster before resuming or dispatching its next beat."
  def recover_hostile_initiative(%{busy: busy} = state) when not is_nil(busy),
    do: {:ok, state}

  def recover_hostile_initiative(state) do
    world = Session.read_state(state.session)

    if is_nil(world.actor_checkpoint) and is_nil(world.pending_turn) do
      {:ok, candidate} = World.recover_hostile_initiative().(world)

      if candidate == world do
        {:ok, state}
      else
        joined = candidate.initiative_order -- world.initiative_order

        note = %{
          kind: "initiative_recovery",
          joined: joined,
          note:
            dgettext(
              "engine",
              "Se recupera el orden de combate: %{joined} se incorpora al final. Los turnos ya jugados se conservan.",
              joined: Enum.join(joined, ", ")
            )
        }

        case Persistence.persist_roll_change(state, candidate, [], "system", %{}, [note]) do
          {:ok, _} ->
            proposer = Session.current(state.session) || "dm"
            {:ok, _} = Session.update_state(state.session, proposer, fn _ -> {:ok, candidate} end)
            Persistence.broadcast_updated(state)
            {:ok, state}

          {:error, _} ->
            paused = %{state | status: :paused}
            Persistence.persist(paused, :paused)

            Games.append_event(state.game_id, :system, "system", "all", %{
              note:
                dgettext(
                  "engine",
                  "No se pudo guardar la recuperación del orden de combate. La partida está en pausa; reanuda para volver a intentarlo."
                )
            })

            Persistence.broadcast_updated(paused)
            {:error, :initiative_recovery_failed, paused}
        end
      end
    else
      {:ok, state}
    end
  end

  # Save the selected slot before evaluating its effects. The pending marker
  # preserves named DM slots and reaction kind across a stop before the commit.
  def start_turn(state, to, kind \\ "main") do
    world = Session.read_state(state.session)
    name = World.resolve_combatant(world, to)
    proposer = Session.current(state.session) || "dm"

    if world.phase == :combat and is_binary(name) and kind in ["main", "reaction"] do
      pending = Map.put(world, :pending_turn, %{"combatant" => name, "kind" => kind})

      case Persistence.persist_roll_change(state, pending, [], proposer, %{}) do
        {:ok, _} ->
          {:ok, _} = Session.update_state(state.session, proposer, fn _ -> {:ok, pending} end)
          commit_turn_start(state, pending, name, kind, proposer)

        {:error, _} ->
          pause_turn_start(state)
      end
    else
      case Session.update_state(state.session, proposer, World.set_current_combatant(name, kind)) do
        {:ok, _} -> maybe_end_combat(state)
        {:error, _} -> state
      end
    end
  end

  @doc "Retry a durable turn start before any actor or coordinator beat."
  def retry_pending_turn(state) do
    world = Session.read_state(state.session)

    case Map.get(world, :pending_turn) do
      %{"combatant" => name, "kind" => kind} ->
        {:ok, _} = Session.handoff(state.session, World.controller_of(world, name))
        state = %{state | loop_phase: :actor, pending_mini: kind == "reaction"}
        {:retried, start_turn(state, name, kind)}

      _ ->
        :none
    end
  end

  defp commit_turn_start(state, world, name, kind, proposer) do
    roller = state.roller || (&Dragonex.Dice.roll/1)
    {:ok, recorder} = RollLog.start()
    roll_log = %RollLog{base: roller, recorder: recorder}

    try do
      with {:ok, candidate} <- World.set_current_combatant(name, kind, roller, roll_log).(world),
           candidate = Map.put(candidate, :pending_turn, nil),
           {:ok, entries} <-
             Persistence.persist_roll_change(
               state,
               candidate,
               RollLog.entries(recorder),
               proposer,
               %{round: world.round, phase: world.phase, timing: "turn_start", combatant: name}
             ) do
        {:ok, _} = Session.update_state(state.session, proposer, fn _ -> {:ok, candidate} end)
        Persistence.publish_rolls(state, entries)
        maybe_end_combat(state)
      else
        {:error, _} -> pause_turn_start(state)
      end
    after
      RollLog.stop(recorder)
    end
  end

  defp pause_turn_start(state) do
    paused = %{state | status: :paused}
    Persistence.persist(paused, :paused)

    Games.append_event(state.game_id, :system, "system", "all", %{
      note:
        dgettext(
          "engine",
          "No se pudo guardar el inicio del turno. La partida está en pausa; reanuda para volver a intentarlo."
        )
    })

    Persistence.broadcast_updated(paused)
    paused
  end

  # Engine-driven combat resolution. The DM used to be solely responsible for
  # calling end_combat when every enemy was down — and frequently forgot, leaving
  # the loop cycling turns through dead enemies. Now the engine ends combat the
  # moment `World.combat_over?/1` is true (at most one conscious side left).
  def maybe_end_combat(state) do
    world = Session.read_state(state.session)

    if world.phase == :combat and Dragonex.World.combat_over?(world) do
      with next when not is_nil(next) <- Session.current(state.session),
           {:ok, candidate} <- World.end_combat().(world) do
        {prepared, dropped_notes} = Turnmaster.prune_stale_intents(state, candidate.phase)
        notes = [%{note: dgettext("engine", "⚔ El combate termina.")} | dropped_notes]

        case Persistence.persist_roll_change(prepared, candidate, [], next, %{}, notes) do
          {:ok, _} ->
            {:ok, _} = Session.update_state(state.session, next, fn _ -> {:ok, candidate} end)
            Persistence.broadcast_updated(prepared)
            prepared

          {:error, _} ->
            paused = %{state | status: :paused, busy: nil, loop_phase: :actor}
            Persistence.persist(paused, :paused)

            Games.append_event(state.game_id, :system, "system", "all", %{
              note:
                dgettext(
                  "engine",
                  "No se pudo guardar el cierre del combate. La partida está en pausa; reanuda para volver a intentarlo."
                )
            })

            Persistence.broadcast_updated(paused)
            throw({:combat_end_commit_failed, paused})
        end
      else
        _ -> state
      end
    else
      state
    end
  end

  # Ghost-combat recovery. When the DM brings a new living enemy into the scene
  # (spawn_monster) during exploration but never rolls initiative, the partida
  # used to stall: the DM would re-narrate "aparece un esqueleto" turn after
  # turn while the loop stayed in exploration, burning 4-5 turns of false-start
  # combat before initiative finally fired. Here the engine detects that a beat
  # INTRODUCED a hostile (enemies_after has names enemies_before didn't) while
  # the world is still in exploration, and forces a roll_initiative itself so the
  # fight is sequenced immediately. Comparing before/after — rather than acting
  # on the mere presence of enemies — avoids false positives at partida start
  # (where monsters may already be in the world during the scene-setting beat).
  def maybe_force_combat(state, enemies_before) do
    world = Session.read_state(state.session)

    newly_hostile =
      world
      |> Dragonex.World.living_enemies()
      |> MapSet.difference(enemies_before)

    cond do
      world.phase != :exploration ->
        state

      MapSet.size(newly_hostile) == 0 ->
        state

      not Dragonex.World.has_living_pcs?(world) ->
        # Nobody to fight back — don't start combat against an empty party.
        state

      Session.current(state.session) in [nil, ""] ->
        state

      true ->
        proposer = Session.current(state.session)
        roller = state.roller || (&Dragonex.Dice.roll/1)
        {:ok, recorder} = RollLog.start()
        roll_log = %RollLog{base: roller, recorder: recorder}

        try do
          {:ok, _msg, change} = Dragonex.Actions.initiative(world, roller, roll_log)

          with {:ok, candidate} <- change.(world),
               {:ok, entries} <-
                 Persistence.persist_roll_change(
                   state,
                   candidate,
                   RollLog.entries(recorder),
                   proposer,
                   %{round: world.round, phase: world.phase, timing: "forced_initiative"},
                   [
                     %{
                       note:
                         dgettext(
                           "engine",
                           "⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente."
                         )
                     }
                   ]
                 ) do
            {:ok, _} = Session.update_state(state.session, proposer, fn _ -> {:ok, candidate} end)
            Persistence.publish_rolls(state, entries)

            Logger.info(
              "dragonex game #{state.game_id} forced combat start after new enemies: #{inspect(MapSet.to_list(newly_hostile))}"
            )
          else
            {:error, reason} -> throw({:engine_commit_failed, reason})
          end
        after
          RollLog.stop(recorder)
        end

        state
    end
  end

  # Main turns mark acted_this_round (mini-turns do not — see the caller).
  def main_combatant(world) do
    owner = world.turn_owner
    budget = Map.get(world.turn_state, owner, %{})

    cond do
      world.phase != :combat ->
        nil

      world.current_combatant not in [nil, ""] ->
        world.current_combatant

      budget["round"] == world.round and budget["ended"] != true and
          not MapSet.member?(world.acted_this_round || MapSet.new(), owner) ->
        owner

      true ->
        nil
    end
  end

  def mark_actor_acted(state, name) when is_binary(name) do
    world = Session.read_state(state.session)
    # Initiative can begin inside a scene-setting beat. A committed action
    # identifies its real slot through TurnBudget even before start_turn has
    # run. A scene transition by itself does not spend any character's turn.
    marked = main_combatant(world)

    if world.phase == :combat and marked in world.initiative_order do
      proposer = Session.current(state.session) || name

      case Session.update_state(state.session, proposer, Dragonex.World.mark_acted(marked)) do
        {:ok, _} -> state
        {:error, _} -> state
      end
    else
      state
    end
  end

  def mark_actor_acted(state, _), do: state

  @doc """
  Recover the floor from canonical combat slots, independent of the legacy
  policy cursor. Named TurnMaster handoffs do not move that cursor, and a
  phase change resets it, so end_turn alone can repeat an already used slot.

  A mini-turn returns to its unfinished main owner. Otherwise pick the first
  unspent living slot (including downed PCs' death saves). Exploration keeps
  the WorldDriven cursor and the opener can retain its current participant.
  """
  def fallback_turn(state, opts \\ []) do
    world = Session.read_state(state.session)

    if world.phase == :combat do
      mini? = Keyword.get(opts, :mini, false)
      next = next_main_combatant(world, mini?)

      # Also recover a persisted fully-spent round. Normal settlement already
      # advanced it; the cleared ledger prevents a second increment here.
      world =
        if is_nil(next) and World.round_complete?(world, World.combat_cycle(world)) do
          maybe_advance_round(state, Session.current(state.session), :combat)
          Session.read_state(state.session)
        else
          world
        end

      case next_main_combatant(world, mini?) do
        nil ->
          state

        combatant ->
          case Session.handoff(state.session, World.controller_of(world, combatant)) do
            {:ok, _} ->
              state = start_turn(state, combatant)
              %{state | interrupted: nil, pending_mini: false, last_was_mini: false}

            {:error, reason} ->
              Logger.warning(
                "dragonex game #{state.game_id} fallback handoff failed: #{inspect(reason)}"
              )

              state
          end
      end
    else
      current = Session.current(state.session)

      cond do
        current in [nil, ""] ->
          Session.handoff(state.session, "dm")

        Keyword.get(opts, :advance, true) ->
          case Session.end_turn(state.session, current) do
            {:ok, _} -> :ok
            {:error, _} -> Session.handoff(state.session, "dm")
          end

        true ->
          :ok
      end

      start_turn(state, Session.current(state.session))
    end
  end

  @doc "Next unspent initiative slot, or an interrupted unfinished main turn."
  def next_main_combatant(world, mini? \\ false) do
    cycle = World.combat_cycle(world)
    acted = world.acted_this_round || MapSet.new()
    owner = world.turn_owner
    budget = Map.get(world.turn_state, owner, %{})

    if mini? and owner in cycle and not MapSet.member?(acted, owner) and
         budget["round"] == world.round and budget["ended"] != true do
      owner
    else
      Enum.find(cycle, &(not MapSet.member?(acted, &1)))
    end
  end

  # Advance the round when every conscious combat participant has spent a main
  # turn this round (`acted_this_round`, D25). Falls back to the legacy "last of
  # the WorldDriven cycle" heuristic when the set is empty (e.g. mid-migration
  # worlds or pure WorldDriven fallback streaks that never marked anyone).
  def maybe_advance_round(state, acted, :combat) do
    world = Session.read_state(state.session)

    if world.phase == :combat do
      cycle = Dragonex.World.combat_cycle(world)

      complete? =
        cond do
          cycle == [] ->
            false

          MapSet.size(world.acted_this_round || MapSet.new()) > 0 ->
            Dragonex.World.round_complete?(world, cycle)

          true ->
            length(cycle) > 1 and acted == List.last(cycle)
        end

      if complete? do
        with next when not is_nil(next) <- Session.current(state.session),
             {:ok, _} <- Session.update_state(state.session, next, Dragonex.World.next_round()) do
          :ok
        end
      end
    end

    :ok
  end

  def maybe_advance_round(_state, _acted, _beat_phase), do: :ok
end
