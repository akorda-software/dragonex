defmodule Dragonex.GameClockContextTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Archetypes, Game, Games, Rest, World}
  alias ExAgent.{Models.Test, Server}

  @old_scene "El patio de la posada. El encargo está pendiente."
  @new_scene "El cuarto de la posada por la mañana. El encargo está cerrado."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game do
    {:ok, game} =
      Games.create_game(
        title: "Una noche, un mismo reloj",
        scene: @old_scene,
        roster: [{Archetypes.fighter(), :human}, {Archetypes.rogue(), :ai}]
      )

    world = Games.load_world(game)
    {:ok, world} = World.add_fact("El encargo terminó y la recompensa está pagada.").(world)
    {:ok, world} = World.advance_time(3600).(world)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    game
  end

  test "party-rest tool feedback gives the committed clock before recording the room and surviving restart" do
    game = game()
    parent = self()

    record = fn messages, _ ->
      world = Game.world(Dragonex.Game.Supervisor.whereis(game.id))
      send(parent, {:committed_rest_feedback, inspect(messages, limit: :infinity), world})
      tool_calls([call("set_scene", %{"narration" => @new_scene})])
    end

    model = %Test{
      script: [
        tool_calls([call("rest_party", %{"targets" => ["Thane", "Vex"], "kind" => "long"})]),
        record,
        narration("Thane, ¿qué quieres observar esta mañana?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert_receive {:committed_rest_feedback, context, before_recording}
    assert before_recording.elapsed_seconds == 32400
    assert before_recording.scene == @old_scene
    assert context =~ "Tiempo del mundo tras el descanso: 32400 s"
    assert context =~ "set_scene"
    assert context =~ "sin mover ni hacer actuar a los PCs"
    assert Game.world(pid).scene == @new_scene
    assert Game.world(pid).elapsed_seconds == 32400
    assert :ok == Game.pause(pid)
    saved = Games.load_world(Games.get_game(game.id))
    assert saved == Game.world(pid)
    assert :ok == stop_supervised({Game, game.id})
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(pid) == saved
    assert Game.status(pid) == :paused
    assert Rest.long_rest_wait(Game.world(pid), "Thane") == 57600
    assert {:error, _} = Rest.validate(Game.world(pid), "Thane", :long)
  end

  test "the responding PC receives the current clock, daily limit and canonical completion after rehydration" do
    game = game()
    world = Games.load_world(Games.get_game(game.id))
    {:ok, _, rest} = Actions.rest_party(world, ["Thane", "Vex"], "long", fn _ -> 1 end)
    {:ok, world} = rest.(world)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    parent = self()

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [
                narration("—Vex, ¿qué observas esta mañana?"),
                narration("Thane, ¿qué quieres observar?")
              ]
            }
          ]}}
      )

    response = fn messages, _ ->
      send(parent, {:pc_clock_context, inspect(messages, limit: :infinity)})
      narration("—El encargo está cerrado; me apetece una mañana tranquila.")
    end

    assert :ok ==
             Server.set_model(:sys.get_state(pid).pc_agents["Vex"], %Test{script: [response]})

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Vex, ¿qué observas esta mañana?")
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert_receive {:pc_clock_context, context}
    assert context =~ "Tiempo del mundo: 32400 s transcurridos"
    assert context =~ "Descanso largo: beneficio disponible en 57600 s"
    assert context =~ "Escena registrada: #{@old_scene}"
    assert context =~ "El encargo terminó y la recompensa está pagada."
    assert context =~ "RESPONDER a Thane"
    assert Game.world(pid) == world
    assert Games.load_world(Games.get_game(game.id)) == world
  end
end
