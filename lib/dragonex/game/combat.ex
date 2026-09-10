defmodule Dragonex.Game.Combat do
  @moduledoc """
  Engine-driven combat bookkeeping: ending combat when it's over, forcing
  initiative when a beat spawns hostiles without rolling it, marking actors as
  acted and advancing the round.

  Extracted from `Dragonex.Game`. These functions run inside the Game
  GenServer's process and return the mutated state (single-writer, D6) — the
  engine, not the DM, owns these transitions.
  """

  require Logger

  alias Dragonex.Game.Turnmaster
  alias ExAgent.Session

  # Engine-driven combat resolution. The DM used to be solely responsible for
  # calling end_combat when every enemy was down — and frequently forgot, leaving
  # the loop cycling turns through dead enemies. Now the engine ends combat the
  # moment `World.combat_over?/1` is true (at most one conscious side left).
  def maybe_end_combat(state) do
    world = Session.read_state(state.session)

    if world.phase == :combat and Dragonex.World.combat_over?(world) do
      with next when not is_nil(next) <- Session.current(state.session),
           {:ok, _} <- Session.update_state(state.session, next, Dragonex.World.end_combat()) do
        {:ok, _} =
          Dragonex.Games.append_event(state.game_id, :system, "system", "all", %{
            note: "⚔ El combate termina."
          })
      end

      Turnmaster.prune_stale_intents(state)
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

      true ->
        {:ok, _msg, change} = Dragonex.Actions.initiative(world, state.roller)

        with next when not is_nil(next) <- Session.current(state.session),
             {:ok, _} <- Session.update_state(state.session, next, change) do
          {:ok, _} =
            Dragonex.Games.append_event(state.game_id, :system, "system", "all", %{
              note: "⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente."
            })

          Logger.info(
            "dragonex game #{state.game_id} forced combat start after new enemies: #{inspect(MapSet.to_list(newly_hostile))}"
          )
        end

        state
    end
  end

  # Main turns mark acted_this_round (mini-turns do not — see the caller).
  def mark_actor_acted(state, name) when is_binary(name) do
    world = Session.read_state(state.session)

    if world.phase == :combat do
      marked = world.current_combatant || name
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
