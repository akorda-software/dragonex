defmodule Dragonex.InitiativeRosterCommitTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Archetypes, Monsters, World}

  defp world do
    Enum.reduce(
      [Archetypes.fighter(), Archetypes.wizard(), Archetypes.rogue()],
      World.new(),
      fn character, acc ->
        {:ok, next} = World.add_character(character).(acc)
        next
      end
    )
  end

  test "an initiative prepared before a spawn cannot omit the newly committed creature" do
    {:ok, before} = World.add_character(Monsters.goblin(name: "goblin")).(world())
    {:ok, _, prepared} = Actions.initiative(before, fn _ -> 10 end)
    {:ok, spawned} = World.add_character(Monsters.skeleton(name: "esqueleto")).(before)
    {:ok, spawned} = World.join_initiative("esqueleto").(spawned)
    assert {:error, reason} = prepared.(spawned)
    assert reason =~ "combatientes"
    assert spawned.phase == :exploration and spawned.initiative_order == []
    assert spawned.characters["esqueleto"].hp == 13
  end

  test "departure, unconsciousness and changed initiative modifiers invalidate prepared rolls" do
    {:ok, before} = World.add_character(Monsters.skeleton(name: "esqueleto")).(world())
    {:ok, _, prepared} = Actions.initiative(before, fn _ -> 10 end)
    {:ok, absent} = World.leave_scene("esqueleto", "Sale por la puerta.").(before)
    {:ok, down} = World.apply_damage("esqueleto", 13).(before)
    different_dex = put_in(before.characters["esqueleto"].dex, 18)

    for changed <- [absent, down, different_dex] do
      assert {:error, _} = prepared.(changed)
      assert changed.phase == :exploration
    end
  end

  test "fresh rolls include every eligible creature once and unrelated scene changes remain valid" do
    {:ok, before} = World.add_character(Monsters.skeleton(name: "esqueleto")).(world())
    owner = self()

    roller = fn sides ->
      send(owner, {:initiative_die, sides})
      10
    end

    {:ok, _, prepared} = Actions.initiative(before, roller)
    for _ <- 1..4, do: assert_receive({:initiative_die, 20})
    refute_receive {:initiative_die, _}, 10
    {:ok, changed} = World.set_scene("La puerta está abierta.").(before)
    assert {:ok, committed} = prepared.(changed)
    assert committed.initiative_order == ["Vex", "Lyra", "esqueleto", "Thane"]
    assert committed.characters == changed.characters and committed.scene == changed.scene
    assert committed.phase == :combat
    assert {:error, "ya hay un combate en curso"} = prepared.(committed)
    refute_receive {:initiative_die, _}, 10
  end
end
