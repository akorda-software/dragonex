defmodule Dragonex.GameReactionRehydrationTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Archetypes, Game, Games, Monsters, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp roller(_), do: 1

  defp paused_reaction(kind) do
    {:ok, game} =
      Games.create_game(
        title: "Paused reaction",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), if(kind == :ai, do: :ai, else: :human)},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ],
        initiative: ["g1", "Thane", "g2", "Lyra"]
      )

    world = Games.load_world(Games.get_game(game.id))
    {:ok, world} = World.mark_acted("g1").(world)
    {:ok, world} = World.set_current_combatant("Thane").(world)
    {:ok, _, wind} = Actions.second_wind(world, "Thane", &roller/1)
    {:ok, world} = wind.(world)
    budget = world.turn_state["Thane"]
    reactor = if kind == :monster, do: "g2", else: "Lyra"
    {:ok, world} = World.set_current_combatant(reactor, "reaction").(world)
    controller = World.controller_of(world, reactor)
    {:ok, _} = Games.save_state(game.id, world, controller, world.round, :paused)
    {game, controller, budget}
  end

  defp resumed_game(game, script) do
    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: script}, roller: &roller/1]}}
      )

    assert Game.status(pid) == :paused
    assert :ok == Game.resume(pid)
    pid
  end

  defp assert_returned(pid, game, budget) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    world = Game.world(pid)
    assert world.phase == :combat
    assert world.round == 1
    assert world.current_combatant == "Thane"
    assert world.turn_owner == "Thane"
    assert world.turn_kind == "main"
    assert world.acted_this_round == MapSet.new(["g1"])
    assert world.turn_state["Thane"] == budget
    assert world.characters["Thane"].second_wind_used
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "reopening a paused human reaction does not consume that PC's main slot" do
    {game, controller, budget} = paused_reaction(:human)
    pid = resumed_game(game, [narration("Lyra se interpone sin atacar.")])
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == controller), 5_000)
    assert {:ok, _} = Game.declare(pid, controller, "Me interpongo sin atacar.")
    assert_returned(pid, game, budget)
  end

  test "reopening an AI PC's paused reaction returns the unfinished main turn" do
    {game, _controller, budget} = paused_reaction(:ai)
    pid = resumed_game(game, [narration("Lyra protege el flanco sin atacar.")])
    assert_returned(pid, game, budget)
  end

  test "reopening the DM's named monster reaction preserves the monster's main slot" do
    {game, controller, budget} = paused_reaction(:monster)
    assert controller == "dm"
    owner = self()

    observe = fn messages, _params ->
      send(owner, {:reactor_context, inspect(messages, limit: :infinity)})
      narration("g2 amaga un movimiento sin atacar.")
    end

    pid = resumed_game(game, [observe])
    assert_returned(pid, game, budget)
    assert_receive {:reactor_context, context}
    assert context =~ "Es TU turno (DM) -- actúa por: g2."
  end

  test "a failed reopened reaction keeps its committed spell and does not mark the main ledger" do
    {game, controller, budget} = paused_reaction(:human)

    script = [
      tool_calls([
        call("cast_spell", %{"caster" => "Lyra", "spell" => "shield", "target" => "Lyra"})
      ]),
      fn -> raise "failure after committed reaction" end
    ]

    pid = resumed_game(game, script)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == controller), 5_000)
    assert {:ok, _} = Game.declare(pid, controller, "Uso escudo para protegerme.")
    assert_returned(pid, game, budget)
    world = Game.world(pid)
    assert world.spell_slots["Lyra"][1] == 1
    assert world.turn_state["Lyra"]["reaction"]
    assert Dragonex.Rules.Effects.shielded?(world.characters["Lyra"])
  end
end
