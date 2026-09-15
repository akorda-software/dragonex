defmodule Dragonex.WorldTest do
  @moduledoc """
  The world as a combat state machine: every transition is a change function,
  every invariant is checked. No agents here — pure state transitions.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Character, World}
  alias Dragonex.Heroes.Progression

  defp goblin(hp),
    do: Character.new(name: "goblin", class: "monster", hp: hp, max_hp: 7, side: "enemy")

  defp pc(name), do: Character.new(name: name, class: "fighter", hp: 12, max_hp: 12, side: "pc")

  defp apply!(world, change_fn) do
    assert {:ok, new_world} = change_fn.(world)
    new_world
  end

  describe "apply_damage vs caído (death saves, RAW)" do
    setup do
      downed =
        Character.new(
          name: "goblin",
          class: "monster",
          hp: 0,
          max_hp: 7,
          side: "enemy",
          death_saves: %{successes: 0, fails: 0}
        )

      {:ok, w: apply!(World.new(), World.add_character(downed))}
    end

    test "daño a un caído registra 1 fallo de salvación de muerte", %{w: w} do
      w = apply!(w, World.apply_damage("goblin", 5))
      assert w.characters["goblin"].hp == 0
      assert w.characters["goblin"].death_saves.fails == 1
      assert Enum.any?(w.log, fn {_a, e} -> e =~ "fallo de salvación de muerte" end)
    end

    test "daño de un golpe crítico registra 2 fallos", %{w: w} do
      w = apply!(w, World.apply_damage("goblin", 5, nil, nil, crit: true))
      assert w.characters["goblin"].death_saves.fails == 2
    end

    test "daño 0 tras capas (absorbido por temp_hp) no registra fallos", %{w: w} do
      w = apply!(w, World.apply_temp_hp("goblin", 4))
      w = apply!(w, World.apply_damage("goblin", 4))
      assert w.characters["goblin"].temp_hp == 0
      assert w.characters["goblin"].death_saves.fails == 0
    end

    test "al 3er fallo el personaje muere por la vía existente", %{w: w} do
      w = apply!(w, World.apply_damage("goblin", 5))
      w = apply!(w, World.apply_damage("goblin", 5))
      refute World.dead?(w, "goblin")
      w = apply!(w, World.apply_damage("goblin", 5))
      assert World.dead?(w, "goblin")
    end

    test "un muerto (3 fallos) no acumula más fallos", %{w: w} do
      w = apply!(w, World.apply_damage("goblin", 5))
      w = apply!(w, World.apply_damage("goblin", 5))
      w = apply!(w, World.apply_damage("goblin", 5))
      assert World.dead?(w, "goblin")

      w = apply!(w, World.apply_damage("goblin", 5))
      assert w.characters["goblin"].death_saves.fails == 3
    end

    test "daño a un caído CON pg positivo no toca el tracker", %{w: w} do
      w = apply!(w, World.heal("goblin", 5))
      assert w.characters["goblin"].hp == 5
      w = apply!(w, World.apply_damage("goblin", 3))
      assert w.characters["goblin"].hp == 2
      assert w.characters["goblin"].death_saves.fails == 0
    end
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

    test "temp_hp absorbs damage first; leftover hits hp (D36)" do
      w =
        World.new()
        |> apply!(World.add_character(%{goblin(10) | hp: 10, max_hp: 10, temp_hp: 5}))

      w = apply!(w, World.apply_damage("goblin", 3))
      assert w.characters["goblin"].temp_hp == 2
      assert w.characters["goblin"].hp == 10

      w = apply!(w, World.apply_damage("goblin", 8))
      assert w.characters["goblin"].temp_hp == 0
      assert w.characters["goblin"].hp == 4
    end

    test "5 temp + 8 damage on 10 hp → temp 0, hp 7" do
      w =
        World.new()
        |> apply!(World.add_character(%{goblin(10) | hp: 10, max_hp: 10, temp_hp: 5}))

      w = apply!(w, World.apply_damage("goblin", 8))
      assert w.characters["goblin"].temp_hp == 0
      assert w.characters["goblin"].hp == 7
    end

    test "resistance to fire halves 10 → 5 (D38)" do
      w =
        World.new()
        |> apply!(World.add_character(%{goblin(10) | damage_resistances: ["fire"]}))

      w = apply!(w, World.apply_damage("goblin", 10, "fire"))
      assert w.characters["goblin"].hp == 5
    end

    test "vulnerability doubles 10 → 20 (D38)" do
      w =
        World.new()
        |> apply!(
          World.add_character(%{
            goblin(30)
            | hp: 30,
              max_hp: 30,
              damage_vulnerabilities: ["fire"]
          })
        )

      w = apply!(w, World.apply_damage("goblin", 10, "fire"))
      assert w.characters["goblin"].hp == 10
    end

    test "immunity deals 0 and hp does not change (D38)" do
      w =
        World.new()
        |> apply!(World.add_character(%{goblin(10) | damage_immunities: ["poison"]}))

      w = apply!(w, World.apply_damage("goblin", 10, "poison"))
      assert w.characters["goblin"].hp == 10
    end

    test "resistance and vulnerability to the same type cancel (D38)" do
      w =
        World.new()
        |> apply!(
          World.add_character(%{
            goblin(20)
            | hp: 20,
              max_hp: 20,
              damage_resistances: ["fire"],
              damage_vulnerabilities: ["fire"]
          })
        )

      w = apply!(w, World.apply_damage("goblin", 10, "fire"))
      assert w.characters["goblin"].hp == 10
    end

    test "untyped damage is unchanged (D38 regression)" do
      w =
        World.new()
        |> apply!(
          World.add_character(%{
            goblin(20)
            | hp: 20,
              max_hp: 20,
              damage_resistances: ["fire"],
              damage_vulnerabilities: ["slashing"],
              damage_immunities: ["poison"]
          })
        )

      w = apply!(w, World.apply_damage("goblin", 10))
      assert w.characters["goblin"].hp == 10
    end

    test "5 temp + resist fire 10 → incoming 5, temp absorbs, hp unchanged (D38)" do
      w =
        World.new()
        |> apply!(
          World.add_character(%{
            goblin(10)
            | hp: 10,
              max_hp: 10,
              temp_hp: 5,
              damage_resistances: ["fire"]
          })
        )

      w = apply!(w, World.apply_damage("goblin", 10, "fire"))
      assert w.characters["goblin"].temp_hp == 0
      assert w.characters["goblin"].hp == 10
    end

    test "hellish_resistance treats fire as resistance without listing it (D38)" do
      w =
        World.new()
        |> apply!(
          World.add_character(%{
            goblin(10)
            | racial_traits: ["hellish_resistance"],
              damage_resistances: []
          })
        )

      w = apply!(w, World.apply_damage("goblin", 10, "fire"))
      assert w.characters["goblin"].hp == 5
    end
  end

  describe "apply_temp_hp/2" do
    test "does not stack: keeps the higher value" do
      w = World.new() |> apply!(World.add_character(goblin(7)))
      w = apply!(w, World.apply_temp_hp("goblin", 3))
      assert w.characters["goblin"].temp_hp == 3
      w = apply!(w, World.apply_temp_hp("goblin", 5))
      assert w.characters["goblin"].temp_hp == 5
      w = apply!(w, World.apply_temp_hp("goblin", 3))
      assert w.characters["goblin"].temp_hp == 5
    end

    test "rejects non-positive amount" do
      w = World.new() |> apply!(World.add_character(goblin(7)))
      assert {:error, msg} = World.apply_temp_hp("goblin", 0).(w)
      assert msg =~ "positive"
      assert {:error, _} = World.apply_temp_hp("goblin", -2).(w)
      assert w.characters["goblin"].temp_hp == 0
    end

    test "errors on an unknown character" do
      assert {:error, "no such character: ghost"} = World.apply_temp_hp("ghost", 5).(World.new())
    end
  end

  describe "concentration (D37)" do
    test "set_concentration / clear_concentration" do
      w = World.new() |> apply!(World.add_character(goblin(7)))
      assert w.characters["goblin"].concentrating == nil

      w = apply!(w, World.set_concentration("goblin", "bless"))
      assert w.characters["goblin"].concentrating == "bless"

      w = apply!(w, World.set_concentration("goblin", "shield of faith"))
      assert w.characters["goblin"].concentrating == "shield of faith"

      w = apply!(w, World.clear_concentration("goblin"))
      assert w.characters["goblin"].concentrating == nil

      w = apply!(w, World.clear_concentration("goblin"))
      assert w.characters["goblin"].concentrating == nil
    end

    test "apply_condition of incapacitated-class conditions drops concentration" do
      w =
        World.new()
        |> apply!(World.add_character(%{goblin(7) | concentrating: "bless"}))

      w = apply!(w, World.apply_condition("goblin", "stunned"))
      assert w.characters["goblin"].concentrating == nil
      assert World.has_condition?(w, "goblin", "stunned")
    end

    test "apply_damage does not itself clear concentration" do
      w =
        World.new()
        |> apply!(World.add_character(%{goblin(7) | concentrating: "bless"}))

      w = apply!(w, World.apply_damage("goblin", 3))
      assert w.characters["goblin"].concentrating == "bless"
    end

    test "errors on an unknown character" do
      assert {:error, "no such character: ghost"} =
               World.set_concentration("ghost", "bless").(World.new())

      assert {:error, "no such character: ghost"} =
               World.clear_concentration("ghost").(World.new())
    end
  end

  describe "grant_xp/2" do
    test "L1 +300 reaches threshold and can_level_up? without leveling" do
      w = World.new() |> apply!(World.add_character(pc("hero")))
      hp = w.characters["hero"].hp
      slots = w.spell_slots

      w = apply!(w, World.grant_xp("hero", 300))
      c = w.characters["hero"]
      assert c.xp == 300
      assert c.level == 1
      assert c.hp == hp
      assert w.spell_slots == slots
      assert Progression.can_level_up?(c.level, c.xp)
    end

    test "+100 does not reach next level" do
      w = World.new() |> apply!(World.add_character(pc("hero")))
      w = apply!(w, World.grant_xp("hero", 100))
      c = w.characters["hero"]
      assert c.xp == 100
      assert c.level == 1
      refute Progression.can_level_up?(c.level, c.xp)
    end

    test "rejects non-positive amount" do
      w = World.new() |> apply!(World.add_character(pc("hero")))
      assert {:error, msg} = World.grant_xp("hero", 0).(w)
      assert msg =~ "positive"
      assert {:error, _} = World.grant_xp("hero", -5).(w)
      assert w.characters["hero"].xp == 0
    end

    test "errors on an unknown character" do
      assert {:error, "no such character: ghost"} = World.grant_xp("ghost", 300).(World.new())
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

    test "does not touch temp_hp" do
      w =
        World.new()
        |> apply!(
          World.add_character(
            Character.new(name: "g", class: "m", hp: 3, max_hp: 7, side: "enemy", temp_hp: 5)
          )
        )

      w = apply!(w, World.heal("g", 2))
      assert w.characters["g"].hp == 5
      assert w.characters["g"].temp_hp == 5
    end

    test "does not clear death saves when heal leaves hp at 0" do
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

      w = apply!(w, World.heal("g", 0))
      assert w.characters["g"].hp == 0
      assert w.characters["g"].death_saves == %{successes: 1, fails: 2}
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

  describe "combat_cycle and current_combatant (D34)" do
    test "skips downed enemies, keeps downed PCs" do
      w =
        World.new()
        |> apply!(World.add_character(pc("Thane")))
        |> apply!(World.add_character(goblin(7)))
        |> apply!(
          World.add_character(
            Character.new(name: "g2", class: "monster", hp: 0, max_hp: 7, side: "enemy")
          )
        )
        |> apply!(World.begin_combat(["goblin", "g2", "Thane"]))

      assert World.combat_cycle(w) == ["goblin", "Thane"]

      w = apply!(w, World.apply_damage("Thane", 99))
      assert World.down?(w, "Thane")
      assert World.combat_cycle(w) == ["goblin", "Thane"]
    end

    test "acting? follows current_combatant in combat" do
      w =
        World.new()
        |> apply!(World.add_character(pc("Thane")))
        |> apply!(World.add_character(goblin(7)))
        |> apply!(
          World.add_character(
            Character.new(name: "orc", class: "monster", hp: 7, max_hp: 7, side: "enemy")
          )
        )
        |> apply!(World.begin_combat(["goblin", "orc", "Thane"]))

      w = apply!(w, World.set_current_combatant("orc"))
      assert World.acting?(w, "orc", "dm")
      refute World.acting?(w, "goblin", "dm")
      refute World.acting?(w, "Thane", "dm")
      assert World.resolve_combatant(w, "dm") == "goblin"
      assert World.resolve_combatant(w, "orc") == "orc"
    end
  end
end
