defmodule Dragonex.BlessTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, Spell, Weapon, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.{Combat, Effects}

  defp world do
    cleric =
      Character.new(
        name: "C",
        class: "cleric",
        level: 3,
        hp: 30,
        max_hp: 30,
        spells: [Spells.to_character_spell(Spells.get("bless"), :wis)]
      )

    sword = %Weapon{name: "sword", dice: "1d6", damage_type: "slashing", attack_ability: :str}

    chars =
      for name <- ["A", "B", "D", "E"],
          into: %{},
          do: {name, Character.new(name: name, hp: 30, max_hp: 30, ac: 12, weapons: [sword])}

    World.new(characters: Map.put(chars, "C", cleric), spell_slots: %{"C" => %{1 => 4, 2 => 2}})
  end

  defp seq(values) do
    Process.put(:bless_rolls, values)

    fn sides ->
      [{^sides, value} | rest] = Process.get(:bless_rolls)
      assert value in 1..sides
      Process.put(:bless_rolls, rest)
      value
    end
  end

  defp no_roll(_), do: flunk("unexpected roll")

  defp cast(w, names \\ ["A"], level \\ 1) do
    [target | others] = names

    assert {:ok, message, change} =
             Actions.spell(w, "C", "bless", target, &no_roll/1, nil, level, others)

    assert message =~ "+1d4"
    assert {:ok, next} = change.(w)
    next
  end

  test "one cast grants three targets, including self, using one action and slot" do
    {:ok, w} = World.begin_combat(["C", "A"]).(world())
    {:ok, w} = World.set_current_combatant("C").(w)
    next = cast(w, ["C", "A", "B"])
    for name <- ["C", "A", "B"], do: assert(Effects.blessed?(next.characters[name]))
    refute Effects.blessed?(next.characters["D"])
    assert next.spell_slots["C"][1] == 3
    assert next.characters["C"].concentrating == "bless"
    assert next.effect_expiries["C"]["concentrating"] == 60
    assert next.turn_state["C"]["action"]
    assert {:error, _} = Actions.spell(next, "C", "bless", "D", &no_roll/1)
  end

  test "upcast grants four targets using only a second-level slot" do
    next = cast(world(), ["C", "A", "B", "D"], 2)
    assert next.spell_slots["C"] == %{1 => 4, 2 => 1}
    assert Enum.count(next.characters, fn {_, c} -> Effects.blessed?(c) end) == 4
  end

  test "invalid target lists and unavailable slots reject without spending" do
    w = world()

    for additional <- [["B", "D", "E"], ["A"], ["missing"], [17], "B"] do
      assert {:error, _} = Actions.spell(w, "C", "bless", "A", &no_roll/1, nil, 1, additional)
    end

    empty = %{w | spell_slots: %{"C" => %{1 => 0}}}
    assert {:error, _} = Actions.spell(empty, "C", "bless", "A", &no_roll/1)
    assert w.spell_slots["C"][1] == 4
    refute Effects.blessed?(w.characters["A"])
  end

  test "prepared cast revalidates targets before applying" do
    w = world()
    {:ok, _, change} = Actions.spell(w, "C", "bless", "A", &no_roll/1)
    missing = %{w | characters: Map.delete(w.characters, "A")}
    assert {:error, _} = change.(missing)
    assert missing.spell_slots["C"][1] == 4
  end

  test "weapon attack converts miss to hit with one d4 and reports the bonus" do
    w = cast(world())
    r = seq([{20, 8}, {4, 2}, {6, 3}])
    {:ok, msg, hit} = Actions.attack(w, "A", "B", "sword", r)
    {:ok, next} = hit.(w)
    assert msg =~ "+2 Bless"
    assert next.characters["B"].hp == 27
    assert Process.get(:bless_rolls) == []
  end

  test "natural 1 and 20 retain their attack outcomes and advantage uses only one d4" do
    a = cast(world()).characters["A"]
    weapon = hd(a.weapons)
    assert {:miss, 1, 7} = Combat.attack_roll(a, weapon, 6, seq([{20, 1}, {4, 4}]))
    assert {:crit, 20, 23} = Combat.attack_roll(a, weapon, 99, seq([{20, 20}, {4, 1}]))

    assert {:hit, 9, 13} =
             Combat.attack_roll(a, weapon, 13, seq([{20, 2}, {20, 9}, {4, 2}]), :advantage)

    assert Process.get(:bless_rolls) == []
  end

  test "spell attacks receive Bless, but damage does not" do
    w = cast(world())

    bolt = %Spell{
      name: "fire bolt",
      level: 0,
      kind: :attack,
      casting_ability: :int,
      dice: "1d10",
      damage_type: "fire"
    }

    w = put_in(w.characters["A"].spells, [bolt])
    {:ok, msg, hit} = Actions.spell(w, "A", "fire bolt", "B", seq([{20, 8}, {4, 2}, {10, 3}]))
    {:ok, next} = hit.(w)
    assert msg =~ "+2 Bless"
    assert next.characters["B"].hp == 27
    assert Process.get(:bless_rolls) == []
  end

  test "all six saves get Bless; ability checks and initiative do not" do
    a = cast(world()).characters["A"]

    for ability <- [:str, :dex, :con, :int, :wis, :cha] do
      assert {8, 10, true} = Combat.saving_throw(a, ability, 10, seq([{20, 8}, {4, 2}]))
    end

    assert {8, 8, false} = Combat.ability_check(a, :wis, 10, seq([{20, 8}]))
    assert {8, 8} = Combat.roll_initiative(a, seq([{20, 8}]))
    assert Process.get(:bless_rolls) == []
  end

  test "self-Bless applies to its concentration save and failure removes every linked target" do
    w = cast(world(), ["C", "A"])
    {:ok, kept} = World.apply_damage("C", 1, "fire", seq([{20, 8}, {4, 2}])).(w)
    assert kept.characters["C"].concentrating == "bless"
    assert Effects.blessed?(kept.characters["A"])
    {:ok, lost} = World.apply_damage("C", 1, "fire", seq([{20, 2}, {4, 1}])).(kept)
    refute Effects.blessed?(lost.characters["A"])
    refute Effects.blessed?(lost.characters["C"])
    assert lost.characters["C"].concentrating == nil
    assert Process.get(:bless_rolls) == []
  end

  test "prepared weapon damage also removes Bless from all allies when caster loses concentration" do
    w = cast(world(), ["C", "A"])

    {:ok, _, change} =
      Actions.attack(w, "B", "C", "sword", seq([{20, 15}, {6, 2}, {20, 2}, {4, 1}]))

    {:ok, next} = change.(w)
    refute Effects.blessed?(next.characters["A"])
    refute Effects.blessed?(next.characters["C"])
    assert Process.get(:bless_rolls) == []
  end

  test "incapacitation, dropping, replacement, rage and falling to zero end the sourced effect" do
    w = cast(world(), ["A", "B"])

    for change <- [
          World.apply_condition("C", "stunned"),
          World.clear_concentration("C"),
          World.set_concentration("C", "shield of faith"),
          World.set_raging("C", true),
          World.apply_damage("C", 30, "fire", &no_roll/1)
        ] do
      {:ok, next} = change.(w)
      refute Effects.blessed?(next.characters["A"])
      refute Effects.blessed?(next.characters["B"])
    end
  end

  test "same-spell recast replaces targets and duration, without stacking" do
    w = cast(world(), ["A", "B"])
    {:ok, w} = World.advance_time(40).(w)
    w = cast(w, ["A", "D"])
    refute Effects.blessed?(w.characters["B"])
    assert w.effect_expiries["C"]["concentrating"] == 100

    assert {8, 10, true} =
             Combat.saving_throw(w.characters["A"], :wis, 10, seq([{20, 8}, {4, 2}]))

    assert Process.get(:bless_rolls) == []
  end

  test "different sources do not stack, and dropping one retains the other" do
    w = cast(world())
    other = %{w.characters["C"] | name: "Other", concentrating: nil}
    w = %{w | characters: Map.put(w.characters, "Other", other)}
    {:ok, _, change} = Actions.spell(w, "Other", "bless", "A", &no_roll/1)
    {:ok, w} = change.(w)

    assert {8, 10, true} =
             Combat.saving_throw(w.characters["A"], :wis, 10, seq([{20, 8}, {4, 2}]))

    assert Process.get(:bless_rolls) == []
    {:ok, w} = World.clear_concentration("C").(w)
    assert Effects.blessed?(w.characters["A"])
    {:ok, w} = World.clear_concentration("Other").(w)
    refute Effects.blessed?(w.characters["A"])
  end

  test "JSON round-trip preserves sources and original expiry; legacy concentration invents no targets" do
    w = cast(world())
    {:ok, w} = World.advance_time(59).(w)
    w = w |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert Effects.blessed?(w.characters["A"])
    assert w.effect_expiries["C"]["concentrating"] == 60
    {:ok, w} = World.advance_time(1).(w)
    refute Effects.blessed?(w.characters["A"])
    {:ok, legacy} = World.set_concentration("C", "bless").(world())
    refute Effects.blessed?(legacy.characters["A"])
  end

  test "Bless helps death saves of a downed ally but preserves natural 1 and 20" do
    w = put_in(world().characters["A"].hp, 0) |> cast()

    for {rolls, hp, fails, successes} <- [
          {[{20, 8}, {4, 2}], 0, 0, 1},
          {[{20, 1}, {4, 4}], 0, 2, 0},
          {[{20, 20}, {4, 1}], 1, 0, 0}
        ] do
      {:ok, msg, change} = Actions.death_save(w, "A", seq(rolls))
      {:ok, next} = change.(w)
      assert msg =~ "Bless"
      assert next.characters["A"].hp == hp
      assert next.characters["A"].death_saves == %{fails: fails, successes: successes}
      assert Process.get(:bless_rolls) == []
    end
  end

  test "expired Bless invalidates an attack prepared with its bonus" do
    w = cast(world())
    {:ok, _, change} = Actions.attack(w, "A", "B", "sword", seq([{20, 8}, {4, 2}, {6, 3}]))
    {:ok, lost} = World.clear_concentration("C").(w)
    assert {:error, _} = change.(lost)
  end

  test "spell save and ensuing concentration save each receive their own Bless die" do
    w = cast(world())
    {:ok, w} = World.set_concentration("A", "shield of faith").(w)

    spell = %Spell{
      name: "test blast",
      level: 0,
      kind: :save,
      save_ability: :wis,
      casting_ability: :int,
      dice: "1d8",
      damage_type: "fire"
    }

    w = put_in(w.characters["B"].spells, [spell])
    r = seq([{20, 8}, {4, 2}, {8, 4}, {20, 8}, {4, 2}])
    {:ok, message, change} = Actions.spell(w, "B", "test blast", "A", r)
    {:ok, next} = change.(w)
    assert message =~ "supera la salvación"
    assert message =~ "mantiene la concentración"
    assert next.characters["A"].hp == 28
    assert next.characters["A"].concentrating == "shield of faith"
    assert Process.get(:bless_rolls) == []
  end

  test "Extra Attack stops using Bless after the source loses concentration on the first hit" do
    w = cast(world())
    w = update_in(w.characters["A"], &%{&1 | class: "fighter", level: 5})
    r = seq([{20, 8}, {4, 2}, {6, 2}, {20, 1}, {20, 10}, {6, 2}])
    {:ok, _, change} = Actions.attack(w, "A", "C", "sword", r)
    {:ok, next} = change.(w)
    assert next.characters["C"].hp == 26
    refute Effects.blessed?(next.characters["A"])
    assert Process.get(:bless_rolls) == []
  end

  test "Bless can prevent spending Indomitable, and applies again if a reroll is needed" do
    w = cast(world())
    w = update_in(w.characters["A"], &%{&1 | class: "fighter", level: 9})
    {:ok, w} = World.set_concentration("A", "shield of faith").(w)
    {:ok, kept} = World.apply_damage("A", 1, "fire", seq([{20, 8}, {4, 2}])).(w)
    refute kept.characters["A"].indomitable_used

    {:ok, rerolled} =
      World.apply_damage("A", 1, "fire", seq([{20, 1}, {4, 1}, {20, 8}, {4, 2}])).(w)

    assert rerolled.characters["A"].indomitable_used
    assert rerolled.characters["A"].concentrating == "shield of faith"
    assert Process.get(:bless_rolls) == []
  end

  test "external Bless applies to Relentless Rage's survival save" do
    w = cast(world())
    w = update_in(w.characters["A"], &%{&1 | class: "barbarian", level: 11, raging: true, hp: 1})
    {:ok, next} = World.apply_damage("A", 5, "fire", seq([{20, 8}, {4, 2}])).(w)
    assert next.characters["A"].hp == 1
    assert next.characters["A"].relentless_rage_successes == 1
    assert Process.get(:bless_rolls) == []
  end

  test "bare condition names and unrelated spells never invent a Bless bonus" do
    w = world()
    {:ok, w} = World.apply_condition("A", "blessed").(w)
    assert {8, 8, false} = Combat.saving_throw(w.characters["A"], :wis, 10, seq([{20, 8}]))

    spell = %Spell{
      name: "fire bolt",
      level: 0,
      kind: :attack,
      casting_ability: :int,
      dice: "1d10",
      damage_type: "fire"
    }

    w = put_in(w.characters["C"].spells, [spell])
    assert {:error, _} = Actions.spell(w, "C", "fire bolt", "A", &no_roll/1, nil, nil, ["B"])
  end
end
