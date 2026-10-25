defmodule Dragonex.GameFixtureCleanupTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Character, Game, Games}
  alias Dragonex.Test.GameFixture
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "fixture cleanup lets a committed rest finish and persist before stopping the Game" do
    hero = Character.new(name: "Thane", class: "fighter", side: "pc", hp: 8, max_hp: 14)
    {:ok, game} = Games.create_game(title: "Una noche que termina", roster: [{hero, :human}])
    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("rest_party", %{"targets" => ["Thane"], "kind" => "long"})]),
        fn _, _ ->
          send(parent, {:rest_applied, self()})

          receive do
            :complete -> narration("Thane, ¿qué quieres observar?")
          end
        end
      ]
    }

    scene = %Test{
      script: [
        tool_calls([call("final_result", %{"scene" => "La posada está en calma al amanecer."})])
      ]
    }

    pid = GameFixture.start!({Game, {game.id, [model: model, scene_model: scene]}})
    assert :ok == Game.resume(pid)
    assert_receive {:rest_applied, run}, 2_000
    run_ref = Process.monitor(run)
    assert Game.world(pid).characters["Thane"].hp == 14
    cleanup = Task.async(fn -> GameFixture.quiesce(pid) end)

    try do
      assert :ok == Game.await(pid, &(&1.status == :paused))
      assert Process.alive?(run)
      send(run, :complete)
      assert :ok == Task.await(cleanup, 5_000)
      assert_receive {:DOWN, ^run_ref, :process, ^run, :normal}, 1_000
      assert Game.status(pid) == :paused
      assert :sys.get_state(pid).busy == nil
      world = Game.world(pid)
      assert world.characters["Thane"].hp == 14
      assert world.elapsed_seconds == 28800
      assert Games.load_world(Games.get_game(game.id)) == world
      events = Games.list_events(game.id)

      assert Enum.any?(
               events,
               &(&1.type == :narration and &1.payload["text"] == "Thane, ¿qué quieres observar?")
             )

      assert :ok == stop_supervised({Game, game.id})
      assert Games.load_world(Games.get_game(game.id)) == world
      assert Games.list_events(game.id) == events
    after
      send(run, :complete)
      Task.shutdown(cleanup, :brutal_kill)
    end
  end
end
