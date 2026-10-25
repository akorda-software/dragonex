defmodule Dragonex.GameRestWildShapeFeedbackTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Character, Game, Games}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the DM receives native HP after a shape expires and Game persists the same rest" do
    c =
      Character.new(
        name: "Sylvi",
        class: "druid",
        side: "pc",
        level: 3,
        hp: 6,
        max_hp: 29,
        con: 14,
        wild_shape_uses: 2
      )

    {:ok, game} =
      Games.create_game(
        title: "La noche devuelve la forma original",
        scene: "Una habitación tranquila.",
        roster: [{c, :human}]
      )

    world = Games.load_world(game)
    {:ok, _, transform} = Actions.wild_shape(world, "Sylvi", "wolf")
    {:ok, world} = transform.(world)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("rest_party", %{"targets" => ["Sylvi"], "kind" => "long"})]),
        fn messages, _ ->
          send(parent, {:rest_feedback, inspect(messages, limit: :infinity)})
          narration("Sylvi, ¿qué quieres observar?")
        end
      ]
    }

    scene = %Test{
      script: [
        tool_calls([
          call("final_result", %{
            "scene" => "La habitación de la posada está en calma tras la noche."
          })
        ])
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, scene_model: scene]}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Sylvi" and &1.status == :waiting), 5_000)
    assert_receive {:rest_feedback, context}
    assert context =~ "recupera 23 pg (6 → 29"
    assert :ok == Game.pause(pid)
    after_rest = Game.world(pid)
    assert after_rest.characters["Sylvi"].hp == 29
    assert after_rest.characters["Sylvi"].wild_shape == nil
    assert after_rest.characters["Sylvi"].wild_shape_uses == 2
    assert after_rest.elapsed_seconds == 28800
    assert Games.load_world(Games.get_game(game.id)) == after_rest
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == after_rest
    assert Game.status(reopened) == :paused
  end
end
