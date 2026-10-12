defmodule Dragonex.GameSceneEnvironmentTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games, History}
  alias ExAgent.Models.Test

  @old_scene "La taberna del Ciervo tiene un caldero humeante y una barra de madera. " <>
               "Maribel acaba de dejar caer la pregunta de qué pensáis hacer con el forastero " <>
               "del mercado, ofreciendo seguir sin haber visto nada; ahora se endereza y " <>
               "dobla un trapo con calma, como quien no tiene prisa por la respuesta."
  @scene "En la taberna del Ciervo, un caldero humea junto a la barra de madera."
  @speech "Maribel recoge el trapo y lo dobla con calma. —¿Qué pensáis hacer con el forastero " <>
            "del mercado? —pregunta. Thane, ¿qué quieres responderle?"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the scene recorder separates physical surroundings from NPC speech without deleting the conversation" do
    owner = self()

    {:ok, game} =
      Games.create_game(
        title: "El entorno y la conversación",
        scene: @old_scene,
        roster: [{Archetypes.fighter(), :human}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    recorder = %Test{
      script: [
        fn messages, params ->
          wire = Dragonex.Test.ModelMessages.project(messages)
          system = for m <- wire, m["role"] == "system", do: m["content"]
          send(owner, {:environment_request, Enum.join(system, "\n"), params, wire})
          tool_calls([call("final_result", %{"scene" => @scene})])
        end
      ]
    }

    dm = %Test{
      script: [tool_calls([call("advance_time", %{"seconds" => 120})]), narration(@speech)]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: dm, scene_model: recorder)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", "Espero dos minutos junto a la barra.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert :ok == Game.pause(pid)
    assert_receive {:environment_request, instructions, params, wire}
    assert instructions =~ "No registres diálogos de PNJ"
    assert instructions =~ "gestos pasajeros"
    assert instructions =~ "El historial conserva la conversación"
    assert params.function_tools == []
    assert inspect(wire, limit: :infinity) =~ @old_scene
    assert inspect(wire, limit: :infinity) =~ @speech
    Jason.encode!(wire)

    after_wait = Game.world(pid)
    assert after_wait.scene == @scene
    refute after_wait.scene_refresh_pending
    assert after_wait.elapsed_seconds == 120
    assert after_wait.wait_resolution["elapsed_seconds"] == 120

    assert Map.drop(after_wait, [:scene, :log, :elapsed_seconds, :wait_resolution]) ==
             Map.drop(before, [:scene, :log, :elapsed_seconds, :wait_resolution])

    assert Games.load_world(Games.get_game(game.id)) == after_wait
    assert Codec.decode(Codec.encode(after_wait)) == after_wait
    events = Games.list_events(game.id)

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == @speech)
           ) == 1

    refute Enum.any?(events, &(&1.type == :dice))

    assert Jason.encode!(Dragonex.Test.ModelMessages.project(History.from_events(events))) =~
             "forastero"

    assert {:ok, fresh} = Game.restart(game.id, model: %Test{}, scene_model: %Test{})
    assert Game.world(fresh) == after_wait
    assert Games.list_events(game.id) == events
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end
end
