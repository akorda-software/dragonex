defmodule Dragones.WorldTest do
  @moduledoc """
  The world as a combat state machine: every transition is a change function,
  every invariant is checked. No agents here — pure state transitions.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Character, World}

  defp goblin(hp),
    do: Character.new(name: "goblin", class: "monster", hp: hp, max_hp: 7, side: "enemy")

  defp pc(name), do: Character.new(name: name, class: "fighter", hp: 12, max_hp: 12, side: "pc")

  defp apply!(world, change_fn) do
    assert {:ok, new_world} = change_fn.(world)
    new_world
  end

  describe "add_character/1" do
    test "adds the character and logs its arrival" do
      w = World.new() |> apply!(World.add_character(goblin(7)))
      assert %Character{name: "goblin"} = w.characters["goblin"]
      assert {"dm", "goblin appears"} in w.log
    end

    test "rejects a duplicate name" do
      w = World.new() |> apply!(World.add_character(goblin(7)))
      assert {:error, "character already exists: goblin"} = World.add_character(goblin(7)).(w)
    end
  end

  describe "apply_damage/2" do
    test "reduces hp and is idempotent-safe at 0" do
      w = World.new() |> apply!(World.add_character(goblin(7)))
      w = apply!(w, World.apply_damage("goblin", 3))
      assert w.characters["goblin"].hp == 4
      w = apply!(w, World.apply_damage("goblin", 100))
      assert w.characters["goblin"].hp == 0
    end

    test "errors on an unknown target without mutating the world" do
      w = World.new()
      assert {:error, "no such character: ghost"} = World.apply_damage("ghost", 1).(w)
    end
  end

  describe "heal/2" do
    test "is capped at max_hp and clears the death-save tracker" do
      w =
        World.new()
        |> apply!(
          World.add_character(
            Character.new(
              name: "g",
              class: "m",
              hp: 0,
              max_hp: 7,
              side: "enemy",
              death_saves: %{successes: 1, fails: 2}
            )
          )
        )

      w = apply!(w, World.heal("g", 50))
      assert w.characters["g"].hp == 7
      assert w.characters["g"].death_saves == %{successes: 0, fails: 0}
    end
  end

  describe "begin_combat/1 + end_combat/0" do
    setup do
      w =
        World.new()
        |> apply!(World.add_character(pc("rogue")))
        |> apply!(World.add_character(goblin(7)))

      {:ok, world: w}
    end

    test "transitions to combat and stores the turn order", %{world: w} do
      w = apply!(w, World.begin_combat(["rogue", "goblin"]))
      assert w.phase == :combat
      assert w.initiative_order == ["rogue", "goblin"]
      assert {"dm", "combat begins: rogue → goblin"} in w.log
    end

    test "refuses to begin combat twice", %{world: w} do
      w = apply!(w, World.begin_combat(["rogue", "goblin"]))
      assert {:error, "already in combat"} = World.begin_combat(["rogue", "goblin"]).(w)
    end

    test "refuses unknown combatants", %{world: w} do
      assert {:error, _} = World.begin_combat(["rogue", "dragon"]).(w)
    end

    test "end_combat returns to exploration", %{world: w} do
      w = apply!(w, World.begin_combat(["rogue", "goblin"]))
      assert w.phase == :combat
      w = apply!(w, World.end_combat())
      assert w.phase == :exploration
    end

    test "join_initiative appends a reinforcement mid-combat", %{world: w} do
      w = apply!(w, World.begin_combat(["rogue", "goblin"]))
      orc = Character.new(name: "orc", class: "monster", hp: 15, max_hp: 15, side: "enemy")
      w = apply!(w, World.add_character(orc))
      w = apply!(w, World.join_initiative("orc"))
      assert w.initiative_order == ["rogue", "goblin", "orc"]
    end

    test "join_initiative is a no-op outside combat", %{world: w} do
      # No begin_combat — still exploration.
      w = apply!(w, World.join_initiative("goblin"))
      assert w.initiative_order == []
    end

    test "join_initiative is idempotent", %{world: w} do
      w = apply!(w, World.begin_combat(["rogue", "goblin"]))
      w = apply!(w, World.join_initiative("goblin"))
      assert w.initiative_order == ["rogue", "goblin"]
    end
  end

  describe "combat_over?/1" do
    test "true when only one side still stands" do
      w =
        World.new()
        |> apply!(World.add_character(pc("rogue")))
        |> apply!(World.add_character(goblin(7)))
        |> apply!(World.begin_combat(["rogue", "goblin"]))

      refute World.combat_over?(w)
      w = apply!(w, World.apply_damage("goblin", 7))
      assert World.combat_over?(w)
    end

    test "false outside combat" do
      refute World.combat_over?(World.new())
    end
  end

  describe "apply_death_save/2" do
    setup do
      w =
        World.new()
        |> apply!(
          World.add_character(
            Character.new(name: "hero", class: "fighter", hp: 0, max_hp: 12, side: "pc")
          )
        )

      {:ok, world: w}
    end

    test "three successes are tracked (stable)", %{world: w} do
      w = apply!(w, World.apply_death_save("hero", {:success, 10, 0, 1}))
      w = apply!(w, World.apply_death_save("hero", {:success, 14, 0, 1}))
      w = apply!(w, World.apply_death_save("hero", {:success, 19, 0, 1}))
      assert w.characters["hero"].death_saves.successes == 3
      refute World.dead?(w, "hero")
    end

    test "three fails mark the character dead", %{world: w} do
      w = apply!(w, World.apply_death_save("hero", {:fail, 5, 1, 0}))
      w = apply!(w, World.apply_death_save("hero", {:fail, 8, 1, 0}))
      refute World.dead?(w, "hero")
      w = apply!(w, World.apply_death_save("hero", {:fail, 6, 1, 0}))
      assert World.dead?(w, "hero")
    end

    test "a nat 1 counts as two fails", %{world: w} do
      w = apply!(w, World.apply_death_save("hero", {:crit_fail, 1, 2, 0}))
      assert w.characters["hero"].death_saves.fails == 2
    end

    test "a nat 20 revives at 1 hp with a fresh tracker", %{world: w} do
      w = apply!(w, World.apply_death_save("hero", {:fail, 5, 1, 0}))
      w = apply!(w, World.apply_death_save("hero", {:revive, 20, 0, 0}))
      assert w.characters["hero"].hp == 1
      assert w.characters["hero"].death_saves == %{successes: 0, fails: 0}
      refute World.down?(w, "hero")
    end
  end

  describe "narration" do
    test "set_scene and narrate append to the log, newest first" do
      w = World.new() |> apply!(World.set_scene("a tavern"))
      w = apply!(w, World.narrate("dm", "the door creaks"))
      assert {"dm", "the door creaks"} == hd(w.log)
      assert w.scene == "a tavern"
    end
  end

  describe "controlled_by?/3" do
    setup do
      w =
        World.new()
        |> apply!(World.add_character(pc("Thane")))
        |> apply!(World.add_character(goblin(7)))

      {:ok, world: w}
    end

    test "a PC is controlled only by its own participant id", %{world: w} do
      assert World.controlled_by?(w, "Thane", "Thane")
      refute World.controlled_by?(w, "Thane", "dm")
      refute World.controlled_by?(w, "Thane", "Vex")
    end

    test "a monster is controlled by the DM (any non-PC participant), never by a PC", %{world: w} do
      assert World.controlled_by?(w, "goblin", "dm")
      refute World.controlled_by?(w, "goblin", "Thane")
    end

    test "unknown character -> false", %{world: w} do
      refute World.controlled_by?(w, "ghost", "dm")
    end
  end
end
