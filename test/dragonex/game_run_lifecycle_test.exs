defmodule Dragonex.GameRunLifecycleTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Character, Game, Games, WorldClock}
  alias Dragonex.Game.Supervisor, as: GameSupervisor
  alias Dragonex.Game.RunLifecycle
  alias ExAgent.Message
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "stopping a supervised game cancels its in-flight model request" do
    {game, pid, run, children} = blocked_game()
    ref = Process.monitor(run)

    try do
      assert :ok == Game.pause(pid)
      assert :ok == GameSupervisor.stop_game(game.id)
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert_closed(children)
    after
      cleanup(game.id, run, children)
    end
  end

  test "a normal stop also closes the game session and agent servers" do
    {game, pid, run, children} = blocked_game()
    ref = Process.monitor(run)

    try do
      assert :ok == Game.pause(pid)
      assert :ok == GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert_closed(children)
    after
      cleanup(game.id, run, children)
    end
  end

  test "restart retains the saved world and rejects the old run's late narration" do
    {game, pid, run, children} = blocked_game()
    ref = Process.monitor(run)

    try do
      assert :ok == Game.pause(pid)
      world = Game.world(pid)
      events = Games.list_events(game.id)
      {:ok, reopened} = Game.restart(game.id, model: %Test{})
      assert reopened != pid
      assert Game.status(reopened) == :paused
      assert Game.world(reopened) == world
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      send(run, :release)
      assert Games.list_events(game.id) == events
    after
      cleanup(game.id, run, children)
    end
  end

  test "a killed Game cancels its old run before the supervised replacement resumes" do
    {game, pid, run, children} = blocked_game()
    ref = Process.monitor(run)

    try do
      assert :ok == Game.pause(pid)
      world = Game.world(pid)
      events = Games.list_events(game.id)
      Process.exit(pid, :kill)
      reopened = await_replacement(game.id, pid)
      assert Game.status(reopened) == :paused
      assert Game.world(reopened) == world
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Games.list_events(game.id) == events
    after
      cleanup(game.id, run, children)
    end
  end

  for role <- [:pc, :turnmaster, :scene] do
    test "stopping a game also cancels the blocked #{role} request" do
      {game, pid, run, children} = blocked_game(unquote(role))
      ref = Process.monitor(run)

      try do
        assert :ok == Game.pause(pid)
        assert :ok == GameSupervisor.stop_game(game.id)
        assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
        assert_closed(children)
      after
        cleanup(game.id, run, children)
      end
    end
  end

  test "a watcher exits when its request completes without cancelling its owner" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    request = spawn(fn -> receive do: (:stop -> :ok) end)
    watcher = Dragonex.Game.RunLifecycle.watch([owner], [request])
    ref = Process.monitor(watcher)

    try do
      send(request, :stop)
      assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
      assert Process.alive?(owner)
    after
      send(owner, :stop)
      send(request, :stop)
    end
  end

  test "a normal stop closes an autoplay agent created after bootstrap" do
    {game, pid, run, children} = blocked_game()
    assert :ok == Game.enable_auto_play(pid, "Thane")
    auto = :sys.get_state(pid).pc_agents["Thane"]
    ref = Process.monitor(auto)

    try do
      assert :ok == Game.pause(pid)
      assert :ok == GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^auto, _}, 1_000
    after
      cleanup(game.id, run, [auto | children])
    end
  end

  for owner_key <- [:game_owner, :beat_owner] do
    test "late narration is not persisted after #{owner_key} exits" do
      {:ok, game} =
        Games.create_game(
          title: "Una voz antigua",
          roster: [{Dragonex.Archetypes.fighter(), :human}]
        )

      owner = spawn(fn -> :ok end)
      ref = Process.monitor(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}

      deps = %{
        unquote(owner_key) => owner,
        :beat => %{game_id: game.id, actor: "dm", turn_id: "discarded"}
      }

      state = %{
        deps: deps,
        messages: [
          Message.new_response([%Message.Part.Text{content: "Una voz antigua insiste."}])
        ]
      }

      events = Games.list_events(game.id)
      assert Dragonex.Events.after_model_request(Dragonex.Events, state) == state
      assert Games.list_events(game.id) == events

      assert catch_exit(RunLifecycle.before_tool_execute(RunLifecycle, %{deps: deps}, :call)) ==
               :shutdown
    end
  end

  test "an interrupted beat cancels its request while the Game remains alive" do
    beat = spawn(fn -> receive do: (:stop -> :ok) end)
    request = spawn(fn -> receive do: (:stop -> :ok) end)
    watcher = RunLifecycle.watch([self(), beat], [request])
    ref = Process.monitor(request)
    watcher_ref = Process.monitor(watcher)

    try do
      send(beat, :stop)
      assert_receive {:DOWN, ^ref, :process, ^request, :shutdown}, 1_000
      assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, :normal}, 1_000
      assert Process.alive?(self())
    after
      send(beat, :stop)
      send(request, :stop)
    end
  end

  defp blocked_game(role \\ :dm) do
    hero = Character.new(name: "Thane", class: "fighter", side: "pc", hp: 12, max_hp: 12)

    roster =
      if role == :pc do
        human = Character.new(name: "Mara", class: "wizard", side: "pc", hp: 8, max_hp: 8)
        [{hero, :ai}, {human, :human}]
      else
        [{hero, :human}]
      end

    {:ok, game} =
      Games.create_game(
        title: "Una narración que espera",
        scene: "La posada permanece tranquila.",
        roster: roster
      )

    world = Games.load_world(game)
    world = if role == :scene, do: WorldClock.advance(world, 1), else: world
    current = if role == :pc, do: "Thane", else: "dm"
    {:ok, _} = Games.save_state(game.id, world, current, world.round, :paused)
    parent = self()

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, {:blocked_run, self()})

          receive do
            :release -> "Una narración tardía llega a la posada."
          end
        end
      ]
    }

    opts =
      case role do
        :turnmaster ->
          [model: %Test{}, turnmaster_model: model]

        :scene ->
          [
            model: %Dragonex.Test.Narrator{text: "Thane, ¿qué quieres observar?"},
            scene_model: model
          ]

        _ ->
          [model: model]
      end

    {:ok, pid} = Game.ensure_started(game.id, opts)

    if role == :turnmaster do
      :sys.replace_state(pid, &%{&1 | loop_phase: :turnmaster, last_actor: "dm"})
    end

    state = :sys.get_state(pid)
    children = [state.session, state.dm, state.turnmaster | Map.values(state.pc_agents)]
    assert :ok == Game.resume(pid)
    assert_receive {:blocked_run, run}, 2_000
    {game, pid, run, children}
  end

  defp await_replacement(game_id, old_pid, attempts \\ 200)
  defp await_replacement(_game_id, _old_pid, 0), do: flunk("Game was not restarted")

  defp await_replacement(game_id, old_pid, attempts) do
    case GameSupervisor.whereis(game_id) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(5)
        await_replacement(game_id, old_pid, attempts - 1)
    end
  end

  defp cleanup(game_id, run, children) do
    GameSupervisor.stop_game(game_id)

    for pid <- [run | children], Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  defp assert_closed(children) do
    for pid <- children do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end
  end
end
