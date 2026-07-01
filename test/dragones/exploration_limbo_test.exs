defmodule Dragones.ExplorationLimboTest do
  @moduledoc """
  Bug #5 — soft loop before anything happens. The partida cycles for 10+ turns
  of pure narration ("¿empezamos con el círculo?" x N) with nobody acting: no
  ability checks, no spawns, no scene changes. The DM's rule 11 (advance after
  2 stalled turns) wasn't firing reliably in pure exploration.

  Fix: `Dragones.Game.exploration_limbo?/2` detects a backlog of pure narration
  with no mechanical progress and forces the DM onto `dm_advance_instruction/0`,
  which compels it to break the statu quo (spawn / set_scene / NPC / event).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Dragones.Test.Harness

  alias Dragones.{Archetypes, Games, Game}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})
    :ok
  end

  defp narration_count(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.count(fn e -> e.type == :narration end)
  end

  test "a stall of pure narration forces the DM to advance" do
    {:ok, game} =
      Games.create_game(
        title: "limbo",
        scene: "una sala con un círculo mágico",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # Everyone just keeps narrating hesitation — nobody acts. Classic soft loop.
    model = %Test{label: "El grupo sigue deliberando qué hacer sin decidirse."}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragones.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        # Wait until enough narration has piled up for the limbo detector to
        # trip on the DM's turn (it needs >= 6 pure-narration events).
        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> narration_count(game.id) >= 8 end,
                   10_000
                 )
      end)

    assert log =~ "exploration limbo",
           "a prolonged pure-narration stall should force the DM to advance the scene"
  end

  test "progress (an ability check) keeps the partida out of limbo" do
    {:ok, game} =
      Games.create_game(
        title: "limbo",
        scene: "una puerta de roble",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # The bot does an ability_check on its first turn → a :dice event lands,
    # which counts as progress. No limbo nudge should fire on the next DM turns.
    script = [
      tool_calls([call("ability_check", %{"who" => "Thane", "ability" => "str", "dc" => 12})]),
      "Fuerzo la puerta con el hombro.",
      "Observo el resultado.",
      "Sigo inspeccionando la sala."
    ]

    model = %Test{script: script}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragones.Game, {game.id, [model: model, roller: fn _ -> 15 end]}}
          )

        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> narration_count(game.id) >= 5 end,
                   10_000
                 )
      end)

    refute log =~ "exploration limbo",
           "an ability check is real progress — it must keep the partida out of limbo"
  end
end
