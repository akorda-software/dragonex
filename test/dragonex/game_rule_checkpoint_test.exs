defmodule Dragonex.GameRuleCheckpointTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Game.Supervisor, as: GameSupervisor
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test
  alias ExAgent.Session.SharedState

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "an acknowledged rest is durable before the following narration completes" do
    {game, pid, run} = resting_game()

    try do
      world = Game.world(pid)
      assert world.characters["Thane"].hp == 14
      assert world.elapsed_seconds == 28800
      assert Games.load_world(Games.get_game(game.id)) == world
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "restart retains an acknowledged rest and its daily limit" do
    {game, pid, run} = resting_game()
    ref = Process.monitor(run)

    try do
      world = Game.world(pid)
      events = Games.list_events(game.id)
      assert :ok == Game.pause(pid)

      {:ok, reopened} = Game.restart(game.id, model: %Test{})

      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.status(reopened) == :paused
      assert Game.world(reopened) == world
      assert Games.load_world(Games.get_game(game.id)) == world
      assert {:error, _} = Actions.long_rest(Game.world(reopened), "Thane")
      send(run, :complete)
      assert Games.list_events(game.id) == events
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "a human spell keeps healing, spent slot and spent action across an interrupted beat" do
    caster =
      Character.new(
        name: "Cora",
        class: "cleric",
        side: "pc",
        hp: 20,
        max_hp: 20,
        wis: 16,
        spells: [Spells.to_character_spell(Spells.get("cure wounds"), :wis)]
      )

    thane = Character.new(name: "Thane", class: "fighter", side: "pc", hp: 8, max_hp: 14)
    enemy = Character.new(name: "Goblin", side: "enemy", hp: 100, max_hp: 100)

    {:ok, game} =
      Games.create_game(
        title: "Una curación interrumpida",
        roster: [{caster, :human}, {thane, :human}, {enemy, :ai}]
      )

    {:ok, world} = World.begin_combat(["Cora", "Thane", "Goblin"]).(Games.load_world(game))
    {:ok, world} = World.set_current_combatant("Cora").(world)
    {:ok, _} = Games.save_state(game.id, world, "Cora", world.round, :paused)
    parent = self()

    roller = fn sides ->
      send(parent, {:rolled, sides})
      1
    end

    script = [
      tool_calls([
        call("cast_spell", %{"caster" => "Cora", "spell" => "cure wounds", "target" => "Thane"})
      ])
    ]

    {pid, run} = start_blocked(game, script, "Cora", roller: roller)

    try do
      paid = Game.world(pid)
      assert paid.characters["Thane"].hp == 12
      assert paid.spell_slots["Cora"][1] == world.spell_slots["Cora"][1] - 1
      assert paid.turn_state["Cora"]["action"]
      assert Games.load_world(Games.get_game(game.id)) == paid
      assert_receive {:rolled, 8}
      refute_receive {:rolled, _}, 20
      assert :ok == Game.pause(pid)
      {:ok, reopened} = Game.restart(game.id, model: %Test{})
      assert Game.world(reopened) == paid

      assert {:error, _} =
               Actions.spell(paid, "Cora", "cure wounds", "Thane", fn _ ->
                 flunk("must not roll again")
               end)

      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "a paused in-flight tool saves effects without unpausing or dropping queued intents" do
    {game, pid, run} = resting_game()

    try do
      assert :ok == Game.pause(pid)
      assert {:ok, :queued} == Game.declare(pid, "Thane", "Examino la puerta al despertar.")
      deps = active_deps(pid, run)

      assert {:ok, _} =
               Game.commit_rule_change(pid, deps, World.add_fact("La puerta tiene un sello."))

      row = Games.get_game(game.id)
      assert row.status == :paused
      assert row.current_participant == "dm"
      assert row.intents == :sys.get_state(pid).intents
      assert Games.load_world(row) == Game.world(pid)
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "stale turn and session handles cannot evaluate a change or alter the saved world" do
    {game, pid, run} = resting_game()

    try do
      world = Game.world(pid)
      deps = active_deps(pid, run)
      parent = self()

      change = fn _ ->
        send(parent, :unexpected_change)
        {:ok, world}
      end

      for invalid <- [
            put_in(deps.beat.turn_id, "old-turn"),
            put_in(deps.beat.game_id, -1),
            put_in(deps.state.session, self()),
            put_in(deps.state.participant_id, "Thane")
          ] do
        assert {:error, :stale_beat} == Game.commit_rule_change(pid, invalid, change)
      end

      refute_receive :unexpected_change, 20
      assert Game.world(pid) == world
      assert Games.load_world(Games.get_game(game.id)) == world
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "rejected or malformed changes leave both worlds intact and keep the Game alive" do
    {game, pid, run} = resting_game()

    try do
      world = Game.world(pid)
      deps = active_deps(pid, run)

      assert {:error, :rejected} ==
               Game.commit_rule_change(pid, deps, fn _ -> {:error, :rejected} end)

      for change <- [fn _ -> :bad_world end, fn _ -> raise "invalid rule" end] do
        assert {:error, :invalid_world_change} == Game.commit_rule_change(pid, deps, change)
      end

      assert Process.alive?(pid)
      assert Game.world(pid) == world
      assert Games.load_world(Games.get_game(game.id)) == world
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "changes run in the Game process and a completed beat rejects its old handle" do
    {game, pid, run} = resting_game()

    try do
      deps = active_deps(pid, run)
      parent = self()

      assert {:ok, _} =
               Game.commit_rule_change(pid, deps, fn world ->
                 send(parent, {:writer, self()})
                 {:ok, world}
               end)

      assert_receive {:writer, ^pid}
      assert :ok == Game.pause(pid)
      send(run, :complete)
      assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
      assert {:error, :stale_beat} == Game.commit_rule_change(pid, deps, World.advance_time(60))
      assert Game.world(pid).elapsed_seconds == 28800
    after
      GameSupervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  defp resting_game do
    hero = Character.new(name: "Thane", class: "fighter", side: "pc", hp: 8, max_hp: 14)
    {:ok, game} = Games.create_game(title: "Una noche interrumpida", roster: [{hero, :human}])
    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    {pid, run} = start_blocked(game, [tool_calls([call("long_rest", %{"target" => "Thane"})])])
    {game, pid, run}
  end

  defp start_blocked(game, script, actor \\ "dm", opts \\ []) do
    parent = self()

    block = fn _, _ ->
      send(parent, {:tool_applied, self()})
      receive do: (:complete -> narration("Thane, ¿qué quieres observar?"))
    end

    {:ok, pid} =
      Game.ensure_started(game.id, Keyword.put(opts, :model, %Test{script: script ++ [block]}))

    assert :ok == Game.resume(pid)

    if actor != "dm" do
      assert :ok == Game.await(pid, &(&1.current == actor and &1.status == :waiting))
      assert {:ok, :resolving} == Game.declare(pid, actor, "Curo las heridas de Thane.")
    end

    assert_receive {:tool_applied, run}, 2_000
    {pid, run}
  end

  defp active_deps(pid, run) do
    state = :sys.get_state(pid)

    %{
      state: SharedState.new(state.session, state.busy.participant),
      beat: %{game_id: state.game_id, turn_id: state.busy.turn_id},
      beat_owner: run
    }
  end
end
