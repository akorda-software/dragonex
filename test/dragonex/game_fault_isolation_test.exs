defmodule Dragonex.GameFaultIsolationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Archetypes, Character, Game, Games}
  alias Dragonex.Game.Supervisor, as: GameSupervisor
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "a killed Game retains a rule checkpoint and cancels the old narration" do
    hero = Character.new(name: "Thane", class: "fighter", hp: 8, max_hp: 14)
    {:ok, game} = Games.create_game(title: "Descanso y caída", roster: [{hero, :human}])
    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("long_rest", %{"target" => "Thane"})]),
        fn _, _ ->
          send(parent, {:rest_applied, self()})
          receive do: (:complete -> narration("Una narración que llega tarde."))
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model)
    assert :ok == Game.resume(pid)
    assert_receive {:rest_applied, run}, 2_000
    ref = Process.monitor(run)

    try do
      paid = Game.world(pid)
      events = Games.list_events(game.id)
      assert :ok == Game.pause(pid)
      Process.exit(pid, :kill)

      reopened =
        await(fn ->
          case GameSupervisor.whereis(game.id) do
            new when is_pid(new) and new != pid -> new
            _ -> false
          end
        end)

      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(reopened) == paid
      assert Games.load_world(Games.get_game(game.id)) == paid
      assert paid.characters["Thane"].hp == 14
      assert paid.elapsed_seconds == 28800
      assert {:error, _} = Actions.long_rest(paid, "Thane")
      assert Games.list_events(game.id) == events
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "independent table crashes each retain their own restart budget" do
    tables = for i <- 1..4, do: paused_game("Mesa independiente #{i}")

    try do
      reopened =
        for {game, old, world} <- tables do
          Process.exit(old, :kill)

          new =
            await(fn ->
              case GameSupervisor.whereis(game.id) do
                pid when is_pid(pid) and pid != old -> pid
                _ -> false
              end
            end)

          assert Game.world(new) == world
          {game.id, new}
        end

      for {id, pid} <- reopened do
        assert Process.alive?(pid)
        assert GameSupervisor.whereis(id) == pid
      end
    after
      for {game, _, _} <- tables, do: GameSupervisor.stop_game(game.id)
    end
  end

  test "a normal Game exit removes its empty table supervisor" do
    {game, pid, world} = paused_game("Una mesa cerrada normalmente")
    owner = Dragonex.Game.TableSupervisor.whereis(game.id)
    ref = Process.monitor(owner)

    try do
      assert :ok == GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}
      await(fn -> is_nil(Dragonex.Game.TableSupervisor.whereis(game.id)) end)
      {:ok, reopened} = Game.ensure_started(game.id, model: %Test{})
      assert Game.world(reopened) == world
      assert reopened != owner
    after
      GameSupervisor.stop_game(game.id)
    end
  end

  test "public restarts return the Game and preserve both registry lifetimes" do
    {game, pid, world} = paused_game("Una mesa con ajustes")

    try do
      assert {:error, {:already_started, ^pid}} =
               GameSupervisor.start_game(game.id, model: %Test{})

      Enum.reduce(1..4, pid, fn _, old ->
        owner = Dragonex.Game.TableSupervisor.whereis(game.id)
        {:ok, reopened} = Game.restart(game.id, model: %Test{})
        assert reopened != old
        assert reopened != owner
        refute Process.alive?(old)
        refute Process.alive?(owner)
        assert Game.world(reopened) == world
        assert Game.status(reopened) == :paused
        reopened
      end)
    after
      GameSupervisor.stop_game(game.id)
    end
  end

  test "a missing game does not leave a supervisor or consume another table's budget" do
    missing = -System.unique_integer([:positive])
    assert {:error, {:not_found, ^missing}} = Game.ensure_started(missing, model: %Test{})
    await(fn -> is_nil(Dragonex.Game.TableSupervisor.whereis(missing)) end)
    assert is_nil(GameSupervisor.whereis(missing))
  end

  test "four fast crashes in one table do not close a healthy table" do
    {healthy, healthy_pid, world} = paused_game("Una mesa sana")
    {broken, broken_pid, broken_world} = paused_game("Una mesa inestable")
    healthy_ref = Process.monitor(healthy_pid)
    events = Games.list_events(healthy.id)

    try do
      broken_pid =
        Enum.reduce(1..3, broken_pid, fn _, old ->
          Process.exit(old, :kill)

          new =
            await(fn ->
              case GameSupervisor.whereis(broken.id) do
                pid when is_pid(pid) and pid != old -> pid
                _ -> false
              end
            end)

          # Registration precedes init's DB reads. Crash a ready Game rather
          # than interrupting its bootstrap SQL on the shared test connection.
          assert Game.world(new) == broken_world
          new
        end)

      ref = Process.monitor(broken_pid)
      Process.exit(broken_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^broken_pid, :killed}
      refute_receive {:DOWN, ^healthy_ref, :process, ^healthy_pid, _}, 150
      assert GameSupervisor.whereis(healthy.id) == healthy_pid
      assert Game.world(healthy_pid) == world
      assert Games.list_events(healthy.id) == events
      await(fn -> is_nil(GameSupervisor.whereis(broken.id)) end)
      {:ok, reopened} = Game.ensure_started(broken.id, model: %Test{})
      assert Game.world(reopened) == broken_world
      assert Game.status(reopened) == :paused
    after
      GameSupervisor.stop_game(healthy.id)
      GameSupervisor.stop_game(broken.id)
    end
  end

  defp paused_game(title) do
    {:ok, game} = Games.create_game(title: title, roster: [{Archetypes.fighter(), :human}])
    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, model: %Test{})
    {game, pid, world}
  end

  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("The table did not reach its expected state")

  defp await(check, attempts) do
    case check.() do
      false ->
        Process.sleep(5)
        await(check, attempts - 1)

      result ->
        result
    end
  end
end
