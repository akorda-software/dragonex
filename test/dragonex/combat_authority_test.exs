defmodule Dragonex.CombatAuthorityTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Monsters, Tools, World}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  defp context(phase \\ :exploration) do
    world =
      World.new(
        scene: "El camino está despejado.",
        characters: %{
          "Mara" => Archetypes.fighter(name: "Mara"),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue()
        }
      )

    world =
      if phase == :combat do
        {:ok, world} = World.add_character(Monsters.goblin(name: "Goblin")).(world)
        {:ok, world} = World.begin_combat(["Mara", "Goblin", "Lyra", "Vex"]).(world)
        world
      else
        world
      end

    session =
      start_session(
        world: world,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Mara"), p("Lyra"), p("Vex")]
      )

    assert {:ok, _} = Session.start(session)
    {session, world}
  end

  defp ctx(session, actor, roller),
    do: %{deps: %{state: SharedState.new(session, actor), roller: roller}}

  for phase <- [:exploration, :combat] do
    test "PC tools cannot create enemies in #{phase}" do
      {session, before} = context(unquote(phase))

      for actor <- ["Mara", "Lyra", "Vex"] do
        assert {:ok, ^actor} = Session.handoff(session, actor)
        ctx = ctx(session, actor, fn _ -> flunk("Unauthorized RNG") end)

        assert {:error, "RECHAZADO — solo el DM" <> _} =
                 Tools.spawn_monster(ctx, "goblin", "Invasor")

        assert Session.read_state(session) == before
      end
    end

    test "PC tools cannot reroll initiative in #{phase}" do
      {session, before} = context(unquote(phase))

      for actor <- ["Mara", "Lyra", "Vex"] do
        assert {:ok, ^actor} = Session.handoff(session, actor)
        ctx = ctx(session, actor, fn _ -> flunk("Unauthorized RNG") end)
        assert {:error, "RECHAZADO — solo el DM" <> _} = Tools.roll_initiative(ctx)
        assert Session.read_state(session) == before
      end
    end

    test "PC tools cannot end combat in #{phase}" do
      {session, before} = context(unquote(phase))

      for actor <- ["Mara", "Lyra", "Vex"] do
        assert {:ok, ^actor} = Session.handoff(session, actor)
        ctx = ctx(session, actor, fn _ -> flunk("Unauthorized RNG") end)
        assert {:error, "RECHAZADO — solo el DM" <> _} = Tools.end_combat(ctx)
        assert Session.read_state(session) == before
      end
    end
  end

  test "non-DM rejection precedes shared state access and dice" do
    for actor <- [nil, "DM", "Mara"] do
      ctx = ctx(self(), actor, fn _ -> flunk("Unauthorized RNG") end)

      assert {:error, "RECHAZADO — solo el DM" <> _} =
               Tools.spawn_monster(ctx, "goblin", "Invasor")

      assert {:error, "RECHAZADO — solo el DM" <> _} = Tools.roll_initiative(ctx)
      assert {:error, "RECHAZADO — solo el DM" <> _} = Tools.end_combat(ctx)
    end
  end

  test "DM can introduce a bestiary enemy and begin and end combat through the engine" do
    {session, before} = context()
    rolls = start_supervised!({Agent, fn -> [] end})

    roller = fn sides ->
      Agent.update(rolls, &(&1 ++ [sides]))
      10
    end

    ctx = ctx(session, "dm", roller)
    assert {:ok, _} = Tools.spawn_monster(ctx, "goblin", "Goblin")
    spawned = Session.read_state(session)
    assert spawned.characters["Goblin"] == Monsters.goblin(name: "Goblin")
    assert Map.take(spawned.characters, Map.keys(before.characters)) == before.characters
    assert spawned.phase == :exploration

    assert {:ok, _} = Tools.roll_initiative(ctx)
    combat = Session.read_state(session)
    assert combat.phase == :combat
    assert Enum.sort(combat.initiative_order) == ["Goblin", "Lyra", "Mara", "Vex"]
    assert Agent.get(rolls, & &1) == [20, 20, 20, 20]
    assert {:ok, _} = Tools.end_combat(ctx)
    ended = Session.read_state(session)
    assert ended.phase == :exploration
    assert ended.characters == spawned.characters
    assert ended.elapsed_seconds == before.elapsed_seconds
  end

  test "a DM reinforcement joins existing initiative without rerolling anyone" do
    {session, before} = context(:combat)
    assert {:ok, "dm"} = Session.handoff(session, "dm")
    ctx = ctx(session, "dm", fn _ -> flunk("Reinforcement rerolled dice") end)
    assert {:ok, _} = Tools.spawn_monster(ctx, "orc", "Refuerzo")
    after_spawn = Session.read_state(session)
    assert after_spawn.phase == :combat
    assert after_spawn.initiative_order == before.initiative_order ++ ["Refuerzo"]
    assert after_spawn.current_combatant == before.current_combatant
    assert after_spawn.acted_this_round == before.acted_this_round
    assert Map.delete(after_spawn.characters, "Refuerzo") == before.characters
  end
end
