defmodule Dragonex.GameShutdownOrderTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.Game.Supervisor, as: GameSupervisor

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "supervised shutdown lets the current Game operation reply before closing" do
    {:ok, game} =
      Games.create_game(title: "Una operación en curso", roster: [{Archetypes.fighter(), :human}])

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, model: %ExAgent.Models.Test{})
    parent = self()
    ref = Process.monitor(pid)

    operation =
      Task.async(fn ->
        try do
          :sys.replace_state(pid, fn state ->
            send(parent, :operation_started)

            receive do
              :finish_operation -> state
            end
          end)

          :replied
        catch
          :exit, reason -> {:interrupted, reason}
        end
      end)

    assert_receive :operation_started
    stopping = Task.async(fn -> GameSupervisor.stop_game(game.id) end)

    try do
      assert Task.yield(stopping, 100) == nil
      assert Process.alive?(pid)
      send(pid, :finish_operation)
      assert Task.await(operation, 2_000) == :replied
      assert Task.await(stopping, 2_000) == :ok
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
      assert Games.load_world(Games.get_game(game.id)) == world
    after
      send(pid, :finish_operation)
      Task.shutdown(operation, :brutal_kill)
      Task.shutdown(stopping, :brutal_kill)
      GameSupervisor.stop_game(game.id)
    end
  end

  for {role, reason} <- [{:dm, :kill}, {:session, :normal}] do
    test "a stopped #{role} auxiliary still restarts its Game" do
      {game, pid, world} = paused_game()
      child = Map.fetch!(:sys.get_state(pid), unquote(role))
      ref = Process.monitor(pid)

      if unquote(reason) == :normal,
        do: GenServer.stop(child, :normal),
        else: Process.exit(child, unquote(reason))

      assert_receive {:DOWN, ^ref, :process, ^pid, :game_child_down}, 1_000
      reopened = await_replacement(game.id, pid)
      assert Game.status(reopened) == :paused
      assert Game.world(reopened) == world
      assert Games.load_world(Games.get_game(game.id)) == world
      assert :ok == GameSupervisor.stop_game(game.id)
    end
  end

  test "disabling an autoplay agent does not restart the Game" do
    {game, pid, world} = paused_game()
    assert :ok == Game.enable_auto_play(pid, "Thane")
    agent = :sys.get_state(pid).pc_agents["Thane"]
    ref = Process.monitor(agent)
    assert :ok == Game.disable_auto_play(pid, "Thane")
    assert_receive {:DOWN, ^ref, :process, ^agent, :normal}
    # The state request also lets the already queued normal EXIT be handled.
    assert Game.world(pid) == world
    assert Game.status(pid) == :paused
    assert GameSupervisor.whereis(game.id) == pid
    assert :ok == GameSupervisor.stop_game(game.id)
  end

  test "OTP status reports expose operational fields without model credentials" do
    state = %Game{
      game_id: 123,
      status: :paused,
      model: %{api_key: "private-test-value"},
      scene_model: %{api_key: "private-scene-value"}
    }

    report = Game.format_status(%{state: state, message: :unknown})

    assert report.state == %{
             game_id: 123,
             status: :paused,
             loop_phase: :turnmaster,
             last_actor: nil
           }

    refute inspect(report) =~ "private-test-value"
    refute inspect(report) =~ "private-scene-value"
  end

  defp paused_game do
    {:ok, game} =
      Games.create_game(title: "Una mesa pausada", roster: [{Archetypes.fighter(), :human}])

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, model: %ExAgent.Models.Test{})
    {game, pid, world}
  end

  defp await_replacement(game_id, old_pid, attempts \\ 200)
  defp await_replacement(_game_id, _old_pid, 0), do: flunk("Game did not restart")

  defp await_replacement(game_id, old_pid, attempts) do
    case GameSupervisor.whereis(game_id) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(5)
        await_replacement(game_id, old_pid, attempts - 1)
    end
  end
end
