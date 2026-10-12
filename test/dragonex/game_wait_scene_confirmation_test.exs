defmodule Dragonex.GameWaitSceneConfirmationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games}
  alias ExAgent.Models.Test

  @scene "La barra de la taberna está tranquila."
  @wait "Espero tres minutos junto a la barra."
  @answer "La taberna sigue tranquila. Thane, ¿qué deseas preguntar?"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(scene_model) do
    {:ok, game} =
      Games.create_game(
        title: "Una espera sin cambiar el entorno",
        scene: @scene,
        roster: [{Archetypes.fighter(), :human}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    model = %Test{
      script: [
        tool_calls([call("advance_time", %{"seconds" => 180})]),
        narration(@answer),
        narration("La tabernera sirve guiso. Thane, ¿quieres preguntarle algo más?")
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model, scene_model: scene_model)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    {game, pid, before}
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert :ok == Game.pause(pid)
  end

  test "an unchanged recorded wait persists once and a later question needs no second recorder" do
    parent = self()

    recording = fn _, _ ->
      send(parent, :wait_scene_recorded)
      tool_calls([call("final_result", %{"scene" => @scene})])
    end

    recorder = %Test{script: [recording, recording, recording]}

    {game, pid, before} = boot(recorder)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    finish(pid)
    assert_receive :wait_scene_recorded
    confirmed = Game.world(pid)
    refute confirmed.scene_refresh_pending
    assert confirmed.scene == before.scene
    assert confirmed.log == before.log
    assert confirmed.elapsed_seconds == 180
    assert confirmed.characters == before.characters
    assert confirmed.rest_state == before.rest_state
    assert Games.load_world(Games.get_game(game.id)) == confirmed
    assert :ok == Game.resume(pid)

    assert {:ok, :resolving} ==
             Game.declare(pid, "Thane", "Le pregunto a la tabernera: «¿Qué plato sirves hoy?»")

    finish(pid)
    assert Game.world(pid) == confirmed
    refute_received :wait_scene_recorded
    events = Games.list_events(game.id)
    refute Enum.any?(events, &(&1.type == :dice))
    assert {:ok, fresh} = Game.restart(game.id, model: %Test{}, scene_model: recorder)
    assert Game.world(fresh) == confirmed
    assert Games.list_events(game.id) == events
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert Game.world(fresh) == confirmed
    refute_received :wait_scene_recorded
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "pause keeps the wait pending until the recorder confirms and does not resume play" do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, {:wait_scene_blocked, self()})
          receive do: (:finish -> tool_calls([call("final_result", %{"scene" => @scene})]))
        end
      ]
    }

    {game, pid, before} = boot(recorder)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    assert_receive {:wait_scene_blocked, request}, 2_000
    assert Game.world(pid).elapsed_seconds == 180
    assert Game.world(pid).scene_refresh_pending
    assert :ok == Game.pause(pid)
    send(request, :finish)
    assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
    assert Game.status(pid) == :paused
    confirmed = Game.world(pid)
    refute confirmed.scene_refresh_pending
    assert confirmed.scene == before.scene
    assert confirmed.log == before.log
    assert confirmed.characters == before.characters
    assert Games.load_world(Games.get_game(game.id)) == confirmed
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "restart during recording recovers the completed DM and confirms without another clock or narration" do
    parent = self()

    blocked = %Test{
      script: [
        fn _, _ ->
          send(parent, {:wait_scene_recovery, self()})
          receive do: (:finish -> tool_calls([call("final_result", %{"scene" => @scene})]))
        end
      ]
    }

    {game, pid, before} = boot(blocked)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    assert_receive {:wait_scene_recovery, recorder}, 2_000
    assert Game.world(pid).elapsed_seconds == 180
    assert Game.world(pid).scene_refresh_pending
    assert :ok == Game.pause(pid)
    events = Games.list_events(game.id)
    monitor = Process.monitor(recorder)

    unused = %Test{
      script: [
        fn _, _ ->
          send(parent, :unexpected_wait_dm_request)
          "Unused"
        end
      ]
    }

    recording = %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}
    assert {:ok, fresh} = Game.restart(game.id, model: unused, scene_model: recording)
    assert_receive {:DOWN, ^monitor, :process, ^recorder, _}, 1_000
    assert Game.world(fresh).scene_refresh_pending
    assert :ok == Game.resume(fresh)
    finish(fresh)
    confirmed = Game.world(fresh)
    refute confirmed.scene_refresh_pending
    assert confirmed.elapsed_seconds == 180
    assert confirmed.scene == before.scene
    assert confirmed.log == before.log
    assert confirmed.characters == before.characters
    assert Games.load_world(Games.get_game(game.id)) == confirmed

    assert Enum.filter(Games.list_events(game.id), &(&1.type in [:action, :narration, :dice])) ==
             Enum.filter(events, &(&1.type in [:action, :narration, :dice]))

    refute_received :unexpected_wait_dm_request
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end
end
