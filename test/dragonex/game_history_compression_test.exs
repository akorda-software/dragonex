defmodule Dragonex.GameHistoryCompressionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, World}
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the next real DM request compresses an old question safely and applies a declared wait once across restart" do
    {:ok, game} =
      Games.create_game(
        title: "La conversación envejece sin romper el reloj",
        scene: "La barra de la taberna, con un cuenco servido.",
        roster: [{Archetypes.wizard(name: "Mara de la Bruma"), :human}]
      )

    before = Games.load_world(game)
    {:ok, before} = World.advance_time(34200).(before)
    {:ok, _} = Games.save_state(game.id, before, "Mara de la Bruma", before.round, :paused)

    raw =
      File.read!(
        Path.expand("../fixtures/narration/human_history_compression_question.txt", __DIR__)
      )
      |> String.trim()

    {:ok, _} = Games.append_event(game.id, :narration, "Mara de la Bruma", "all", %{text: raw})

    for i <- 1..11 do
      actor = if rem(i, 2) == 0, do: "Vex", else: "dm"

      {:ok, _} =
        Games.append_event(game.id, :narration, actor, "all", %{
          text: "La lámpara sigue encendida: intervención #{i}."
        })
    end

    parent = self()

    clock = fn messages, _ ->
      wire = ModelMessages.project(messages)
      send(parent, {:dm_history_wire, wire})
      Jason.encode!(wire)
      tool_calls([call("advance_time", %{"seconds" => 1200})])
    end

    scene = "La barra de la taberna, con el cuenco vacío y la jarra sobre el mostrador."

    model = %Test{
      script: [
        narration("Termino mi guiso junto a la barra y aguardo a Maribel."),
        clock,
        tool_calls([call("set_scene", %{"narration" => scene})]),
        narration("Mara de la Bruma, ¿qué deseas preguntarle a Maribel ahora?")
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model)

    try do
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Mara de la Bruma"))

      assert {:ok, :resolving} ==
               Game.declare(
                 pid,
                 "Mara de la Bruma",
                 "Espero veinte minutos junto a la barra mientras termino mi guiso."
               )

      assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Mara de la Bruma"))
      assert :ok == Game.pause(pid)
      assert_receive {:dm_history_wire, wire}
      assert Enum.all?(wire, &String.valid?(&1["content"]))
      assert Jason.decode!(Jason.encode!(wire)) == wire

      assert Enum.any?(
               wire,
               &(&1["role"] == "user" and &1["content"] =~ "CRÓNICA REGISTRADA" and
                   &1["content"] =~ "¿Qué plato sirves hoy")
             )

      after_world = Game.world(pid)
      assert after_world.elapsed_seconds == 35400
      assert after_world.characters == before.characters
      assert after_world.spell_slots == before.spell_slots
      assert after_world.rest_state == before.rest_state
      assert after_world.scene == scene
      assert Games.load_world(Games.get_game(game.id)) == after_world
      events = Games.list_events(game.id)
      refute Enum.any?(events, &(&1.type == :dice))
      refute Enum.any?(events, &String.contains?(&1.payload["note"] || "", "el turno falló"))

      {:ok, fresh} =
        Game.restart(game.id, model: %Test{label: "No debe pedirse una respuesta nueva."})

      assert fresh != pid
      assert Game.world(fresh) == after_world
      assert :ok == Game.resume(fresh)

      assert :ok ==
               Game.await(fresh, &(&1.status == :waiting and &1.current == "Mara de la Bruma"))

      assert :ok == Game.pause(fresh)
      assert Game.world(fresh) == after_world
      assert Games.list_events(game.id) == events
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
