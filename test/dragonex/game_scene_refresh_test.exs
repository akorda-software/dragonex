defmodule Dragonex.GameSceneRefreshTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Rest, World}
  alias ExAgent.{Models.Test, Server}

  @old "El patio inicial. El encargo está pendiente."
  @room "El cuarto de la posada por la mañana. El encargo está cerrado."

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(
        title: "Una escena durable",
        scene: @old,
        roster: [{Archetypes.fighter(), :human}, {Archetypes.rogue(), :ai}]
      )

    world = Games.load_world(game)
    {:ok, world} = World.add_fact("El encargo terminó y está pagado.").(world)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    %{game: game, world: world}
  end

  defp scene_model do
    %Test{script: [tool_calls([call("final_result", %{"scene" => @room})])]}
  end

  defp wait(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  test "the omitted set_scene after a party rest is recorded once, with resources and restart intact",
       %{game: game} do
    model = %Test{
      script: [
        tool_calls([call("rest_party", %{"targets" => ["Thane", "Vex"], "kind" => "long"})]),
        narration("La mañana ilumina el cuarto de la posada. Thane, ¿qué quieres observar?")
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: model, scene_model: scene_model()]}}
      )

    assert :ok == Game.resume(pid)
    wait(pid)
    recorded = Game.world(pid)
    assert recorded.scene == @room
    refute Map.get(recorded, :scene_refresh_pending)
    assert recorded.elapsed_seconds == 28800
    assert recorded.rest_state["Thane"]["last_long_rest_start"] == 0
    assert recorded.rest_state["Vex"]["last_long_rest_start"] == 0
    assert Rest.long_rest_wait(recorded, "Thane") == 57600
    assert {:error, _} = Rest.validate(recorded, "Thane", :long)
    assert recorded.characters["Thane"].hp == recorded.characters["Thane"].max_hp
    assert recorded.facts == ["El encargo terminó y está pagado."]
    assert recorded.spell_slots == %{"Thane" => %{}, "Vex" => %{}}
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    assert Games.load_world(Games.get_game(game.id)) == recorded
    assert :ok == stop_supervised({Game, game.id})

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{}, scene_model: scene_model()]}}
      )

    assert Game.world(pid) == recorded
    assert Game.snapshot(pid).status == :paused
    assert Game.snapshot(pid).current == "Thane"
  end

  test "recording does not erase the pending DM closure and return to the human", %{
    game: game,
    world: world
  } do
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    model = %Test{script: [narration("—Vex, ¿qué ves?"), narration("La posada está en calma.")]}

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: model, scene_model: scene_model()]}}
      )

    assert :ok ==
             Server.set_model(:sys.get_state(pid).pc_agents["Vex"], %Dragonex.Test.Narrator{
               text: "—Veo la ventana."
             })

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Vex, ¿qué ves?")
    wait(pid)
    assert Game.world(pid).scene == @room
    assert Game.world(pid).conversation == nil
    actors = for %{type: :turn, actor: actor} <- Games.list_events(game.id), do: actor
    assert actors == ["Thane", "Vex", "dm"]

    assert Map.drop(Game.world(pid), [:scene, :log, :scene_refresh_pending]) ==
             Map.drop(world, [:scene, :log, :scene_refresh_pending])
  end

  test "a failed recorder keeps the scene pending and does not replay an already committed rest",
       %{game: game} do
    model = %Test{
      script: [
        tool_calls([call("rest_party", %{"targets" => ["Thane", "Vex"], "kind" => "long"})]),
        narration("Thane, ¿qué quieres observar?")
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: model, scene_model: %Test{label: "Sin registro"}]}}
      )

    assert :ok == Game.resume(pid)
    wait(pid)
    failed = Game.world(pid)
    assert failed.scene == @old
    assert Map.get(failed, :scene_refresh_pending)
    assert failed.elapsed_seconds == 28800
    assert :ok == stop_supervised({Game, game.id})

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [narration("Miro la ventana."), narration("El cuarto está en calma.")]
            },
            scene_model: scene_model()
          ]}}
      )

    assert Game.world(pid) == failed
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Observo la ventana sin descansar.")
    wait(pid)
    recovered = Game.world(pid)
    assert recovered.scene == @room
    refute Map.get(recovered, :scene_refresh_pending)

    assert Map.drop(recovered, [:scene, :log, :scene_refresh_pending]) ==
             Map.drop(failed, [:scene, :log, :scene_refresh_pending])
  end

  test "a DM that already records the scene needs no second model request", %{game: game} do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, :unexpected_recorder)
          "Unused"
        end
      ]
    }

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => @room})]),
        narration("Thane, ¿qué observas?")
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, scene_model: recorder]}})

    assert :ok == Game.resume(pid)
    wait(pid)
    assert Game.world(pid).scene == @room
    refute Map.get(Game.world(pid), :scene_refresh_pending)
    refute_received :unexpected_recorder
  end

  test "pause stays responsive while recording and the completed snapshot does not resume play",
       %{game: game} do
    parent = self()

    recorder = %Test{
      script: [
        fn _messages, _params ->
          send(parent, {:recording_blocked, self()})

          receive do
            :finish_recording -> tool_calls([call("final_result", %{"scene" => @room})])
          end
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Dragonex.Test.Narrator{text: "Thane, ¿qué quieres observar?"},
            scene_model: recorder
          ]}}
      )

    assert :ok == Game.resume(pid)
    assert_receive {:recording_blocked, recorder_pid}, 1_000
    assert :ok == Game.pause(pid)
    assert Game.snapshot(pid).status == :paused
    assert Game.world(pid).scene == @old
    assert Map.get(Game.world(pid), :scene_refresh_pending)
    send(recorder_pid, :finish_recording)
    assert :ok == Game.await(pid, &(&1.world.scene == @room and &1.status == :paused), 5_000)
    assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end, 5_000)
    saved = Games.get_game(game.id)
    assert saved.status == :paused
    assert Games.load_world(saved) == Game.world(pid)
    assert :ok == stop_supervised({Game, game.id})

    reopened =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{}, scene_model: scene_model()]}}
      )

    assert Game.status(reopened) == :paused
    assert Game.world(reopened).scene == @room
  end
end
