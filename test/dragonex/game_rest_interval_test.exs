defmodule Dragonex.GameRestIntervalTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias ExAgent.{Models.Test, Server, Session}
  alias ExAgent.Session.SharedState

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp party(targets \\ ["Thane", "Lyra"], kind \\ "short"),
    do: tool_calls([call("rest_party", %{"targets" => targets, "kind" => kind})])

  defp advance(seconds \\ 3600),
    do: tool_calls([call("advance_time", %{"seconds" => seconds})])

  defp closure, do: narration("La hora de descanso termina en calma.")

  defp record(owner, tag, next) do
    fn messages, _ ->
      send(owner, {tag, inspect(messages, limit: :infinity)})
      next
    end
  end

  defp boot(build_script, opts \\ []) do
    thane = Character.new(name: "Thane", class: "fighter", level: 3, hp: 1, max_hp: 30, con: 10)
    lyra = Character.new(name: "Lyra", class: "wizard", level: 3, hp: 1, max_hp: 30, con: 10)

    {:ok, game} =
      Games.create_game(title: "Una hora compartida", roster: [{thane, :human}, {lyra, :human}])

    before = %{Games.load_world(game) | scene_refresh_pending: false}
    actor = Keyword.get(opts, :actor, "dm")
    {:ok, _} = Games.save_state(game.id, before, actor, before.round, :paused)
    rolls = start_supervised!({Agent, fn -> [] end})

    roller = fn sides ->
      Agent.update(rolls, &(&1 ++ [sides]))
      4
    end

    context = %{game: game, before: before, rolls: rolls, roller: roller}
    script = build_script.(context)
    {:ok, pid} = Game.ensure_started(game.id, game_opts(script, roller))
    Map.put(context, :pid, pid)
  end

  defp game_opts(script, roller) do
    [
      model: %Test{script: script},
      roller: roller,
      scene_model: %Test{
        script:
          List.duplicate(
            tool_calls([call("final_result", %{"scene" => "La posada sigue en calma."})]),
            4
          )
      }
    ]
  end

  defp finish(context) do
    assert :ok =
             Game.await(
               context.pid,
               &(&1.status == :waiting and &1.current in ["Thane", "Lyra"]),
               5_000
             )

    assert :ok = Game.pause(context.pid)
    world = Game.world(context.pid)
    assert Games.load_world(Games.get_game(context.game.id)) == world
    world
  end

  defp assert_one_rest(context) do
    world = finish(context)
    assert world.elapsed_seconds == 3600
    assert world.characters["Thane"].hp == 5
    assert world.characters["Lyra"].hp == 5
    assert world.rest_state["Thane"]["hit_dice_used"] == 1
    assert world.rest_state["Lyra"]["hit_dice_used"] == 1
    assert Agent.get(context.rolls, & &1) == [10, 6]
    assert Enum.count(Games.list_events(context.game.id), &(&1.type == :dice)) == 2
    world
  end

  test "the DM rejects individual rests before RNG and records one hour for the entire party" do
    owner = self()

    context =
      boot(fn context ->
        [
          tool_calls([call("short_rest", %{"target" => "Thane"})]),
          tool_calls([call("long_rest", %{"target" => "Lyra"})]),
          fn messages, _ ->
            send(
              owner,
              {:individual_rejected, Agent.get(context.rolls, & &1),
               inspect(messages, limit: :infinity)}
            )

            party()
          end,
          advance(),
          party(["Thane"], "long"),
          record(owner, :extra_interval_rejected, closure())
        ]
      end)

    try do
      assert :ok = Game.resume(context.pid)
      assert_one_rest(context)
      assert_receive {:individual_rejected, [], feedback}
      assert feedback =~ "usa rest_party"
      assert_receive {:extra_interval_rejected, feedback}
      assert feedback =~ "ya registró el intervalo"
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "a paid explicit time interval cannot be charged again as a party rest" do
    owner = self()

    context =
      boot(fn _ -> [advance(300), party(), record(owner, :rest_after_time, closure())] end)

    try do
      assert :ok = Game.resume(context.pid)
      world = finish(context)
      assert world.elapsed_seconds == 300
      assert world.characters == context.before.characters
      assert Agent.get(context.rolls, & &1) == []
      assert_receive {:rest_after_time, feedback}
      assert feedback =~ "ya registró el intervalo"
      refute Enum.any?(Games.list_events(context.game.id), &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "retry reuses the paid rest and rejects new intervals without more dice or time" do
    owner = self()

    context =
      boot(fn _ ->
        [
          party(),
          ExAgent.Message.new_response([], finish_reason: :length),
          party(),
          advance(),
          party(["Lyra", "Thane"]),
          record(owner, :rest_retry, closure())
        ]
      end)

    try do
      assert :ok = Game.resume(context.pid)
      assert_one_rest(context)
      assert_receive {:rest_retry, feedback}
      assert feedback =~ "Resultado ya aplicado antes del fallo"
      assert feedback =~ "ya registró el intervalo"
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "restart retains the paid interval and its receipt until the DM closes it" do
    owner = self()

    context =
      boot(fn _ ->
        [
          party(),
          fn _, _ ->
            send(owner, {:rest_paid, self()})
            receive do: (:complete -> closure())
          end
        ]
      end)

    try do
      assert :ok = Game.resume(context.pid)
      assert_receive {:rest_paid, old_run}, 2_000
      assert :ok = Game.pause(context.pid)
      saved = Game.world(context.pid)
      assert saved.elapsed_seconds == 3600
      assert [%{"name" => "rest_party"}] = saved.actor_checkpoint["tools"]
      assert Games.load_world(Games.get_game(context.game.id)) == saved
      monitor = Process.monitor(old_run)

      script = [party(), advance(), party(["Thane"]), record(owner, :rest_restarted, closure())]
      {:ok, fresh} = Game.restart(context.game.id, game_opts(script, context.roller))
      assert_receive {:DOWN, ^monitor, :process, ^old_run, _}, 1_000
      assert Game.world(fresh) == saved
      assert :ok = Game.resume(fresh)
      assert_one_rest(%{context | pid: fresh})
      assert_receive {:rest_restarted, feedback}
      assert feedback =~ "Resultado ya aplicado antes del fallo"
      assert feedback =~ "ya registró el intervalo"
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "a subsequent declaration opens a new rest interval" do
    context = boot(fn _ -> [party(), closure()] end)

    try do
      assert :ok = Game.resume(context.pid)
      assert_one_rest(context)

      assert :ok =
               Server.set_model(:sys.get_state(context.pid).dm, %Test{
                 script: [narration("Propongo descansar otra hora."), party(), closure()]
               })

      assert :ok = Game.resume(context.pid)
      assert :ok = Game.await(context.pid, &(&1.status == :waiting))
      actor = Session.current(:sys.get_state(context.pid).session)

      assert {:ok, :resolving} =
               Game.declare(context.pid, actor, "Quiero descansar aquí otra hora con el grupo.")

      world = finish(context)
      assert world.elapsed_seconds == 7200
      assert world.characters["Thane"].hp == 9
      assert world.characters["Lyra"].hp == 9
      assert world.rest_state["Thane"]["hit_dice_used"] == 2
      assert world.rest_state["Lyra"]["hit_dice_used"] == 2
      assert Agent.get(context.rolls, & &1) == [10, 6, 10, 6]
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "a PC can still take their individual rest on their own turn" do
    context =
      boot(
        fn _ ->
          [
            tool_calls([call("short_rest", %{"target" => "Thane"})]),
            narration("Descanso por mi cuenta."),
            closure()
          ]
        end,
        actor: "Thane"
      )

    try do
      assert :ok = Game.resume(context.pid)
      assert :ok = Game.await(context.pid, &(&1.status == :waiting and &1.current == "Thane"))

      assert {:ok, :resolving} =
               Game.declare(context.pid, "Thane", "Descanso una hora por mi cuenta.")

      world = finish(context)
      assert world.elapsed_seconds == 3600
      assert world.characters["Thane"].hp == 5
      assert world.characters["Lyra"].hp == 1
      assert Agent.get(context.rolls, & &1) == [10]
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "an interval prepared before another rest commits is rejected at the writer boundary" do
    owner = self()

    context =
      boot(fn _ ->
        [
          fn _, _ ->
            send(owner, {:rest_beat, self()})
            receive do: (:complete -> closure())
          end
        ]
      end)

    try do
      assert :ok = Game.resume(context.pid)
      assert_receive {:rest_beat, run}, 2_000
      assert :ok = Game.pause(context.pid)
      state = :sys.get_state(context.pid)

      deps = %{
        game_owner: context.pid,
        state: SharedState.new(state.session, "dm"),
        beat: %{
          game_id: context.game.id,
          turn_id: state.busy.turn_id,
          actor: "dm",
          round: 1,
          phase: :exploration
        },
        beat_owner: run
      }

      rest_key = {"rest_party", %{"targets" => ["Thane", "Lyra"], "kind" => "short"}}
      time_key = {"advance_time", %{"seconds" => 3600}}
      assert :execute = GenServer.call(context.pid, {:tool_replay, deps, rest_key})
      assert :execute = GenServer.call(context.pid, {:tool_replay, deps, time_key})

      {:ok, _, rest} =
        Actions.rest_party(context.before, ["Thane", "Lyra"], "short", context.roller)

      rest_deps = Map.put(deps, :tool_commit, %{id: make_ref(), key: rest_key})
      time_deps = Map.put(deps, :tool_commit, %{id: make_ref(), key: time_key})

      assert {:ok, paid} = Game.commit_rule_change(context.pid, rest_deps, rest)

      assert {:error, feedback} =
               Game.commit_rule_change(context.pid, time_deps, World.advance_time(3600))

      assert feedback =~ "ya registró el intervalo"
      assert Game.world(context.pid) == paid
      assert Games.load_world(Games.get_game(context.game.id)) == paid
      assert paid.elapsed_seconds == 3600
      assert [%{"name" => "rest_party"}] = paid.actor_checkpoint["tools"]
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end
end
