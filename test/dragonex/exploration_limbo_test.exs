defmodule Dragonex.ExplorationLimboTest do
  @moduledoc """
  Bug #5 — soft loop before anything happens. The partida cycles for 10+ turns
  of pure narration ("¿empezamos con el círculo?" x N) with nobody acting: no
  ability checks, no spawns, no scene changes. The DM's rule 11 (advance after
  2 stalled turns) wasn't firing reliably in pure exploration.

  Fix: `Dragonex.Game.exploration_limbo?/2` detects a backlog of pure narration
  with no mechanical progress and forces the DM onto `dm_advance_instruction/0`,
  which compels it to break the statu quo (spawn / set_scene / NPC / event).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Games, Game}
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
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
    model = %Dragonex.Test.Narrator{text: "El grupo sigue deliberando qué hacer sin decidirse."}

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
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
    owner = self()

    {:ok, game} =
      Games.create_game(
        title: "limbo",
        scene: "una puerta de roble",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # The bot does an ability_check on its first turn → a :dice event lands,
    # which counts as progress. No limbo nudge should fire on the next DM turns.
    lines = [
      "Fuerzo la puerta con el hombro.",
      "Observo el resultado.",
      "Sigo inspeccionando la sala."
    ]

    finish = fn _, _ ->
      send(owner, {:progress_completed, self()})

      receive do
        :finish_progress -> narration(List.last(lines))
      after
        5_000 -> flunk("the completed progress check was not released")
      end
    end

    script = [
      tool_calls([call("ability_check", %{"who" => "Thane", "ability" => "str", "dc" => 12})]),
      narration(Enum.at(lines, 0)),
      narration(Enum.at(lines, 1)),
      finish
    ]

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, nil, before.round, :paused)

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game,
             {game.id,
              [
                model: %Dragonex.Test.Narrator{
                  text: "La puerta conserva las marcas del esfuerzo."
                },
                roller: fn _ -> 15 end
              ]}}
          )

        assert :ok ==
                 Server.set_model(:sys.get_state(pid).pc_agents["Thane"], %Test{script: script})

        assert :ok == Game.resume(pid)
        assert_receive {:progress_completed, request}, 2_000

        try do
          assert :ok == Game.pause(pid)
          send(request, :finish_progress)

          assert :ok ==
                   Game.await(
                     pid,
                     &(&1.status == :paused and :sys.get_state(pid).busy == nil)
                   )

          events = Games.list_events(game.id)

          assert for(
                   e <- events,
                   e.type == :narration and e.actor == "Thane",
                   do: e.payload["text"]
                 ) ==
                   lines

          assert narration_count(game.id) >= 5
          world = Game.world(pid)
          assert world.characters == before.characters
          assert world.spell_slots == before.spell_slots
          assert world.elapsed_seconds == before.elapsed_seconds
          assert Games.load_world(Games.get_game(game.id)) == world
        after
          send(request, :finish_progress)
        end
      end)

    refute log =~ "exploration limbo",
           "an ability check is real progress — it must keep the partida out of limbo"

    refute log =~ "beat failed"

    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :dice)) == 1
    refute Enum.any?(events, &((&1.payload["note"] || "") =~ "turno falló"))
  end
end
