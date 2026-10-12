defmodule Dragonex.ShieldOfFaithTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, RollLog, Weapon, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Effects

  defp world do
    sword = %Weapon{name: "sword", dice: "1d6", damage_type: "slashing", attack_ability: :str}

    spells =
      Enum.map(
        ["shield of faith", "bless", "fire bolt", "cure wounds"],
        &Spells.to_character_spell(Spells.get(&1), :wis)
      )

    c =
      Character.new(
        name: "C",
        class: "cleric",
        level: 3,
        hp: 30,
        max_hp: 30,
        ac: 12,
        spells: spells,
        weapons: [sword]
      )

    a = Character.new(name: "A", hp: 30, max_hp: 30, ac: 12, weapons: [sword])
    b = %{a | name: "B", side: "enemy", spells: spells}

    World.new(
      characters: %{"C" => c, "A" => a, "B" => b},
      spell_slots: %{"C" => %{1 => 4, 2 => 2}}
    )
  end

  defp seq(values) do
    Process.put(:faith_rolls, values)

    fn sides ->
      [{^sides, value} | rest] = Process.get(:faith_rolls)
      assert value in 1..sides
      Process.put(:faith_rolls, rest)
      value
    end
  end

  defp no_roll(_), do: flunk("unexpected die")

  defp cast(w, target \\ "A", level \\ 1) do
    {:ok, message, change} =
      Actions.spell(w, "C", "shield of faith", target, &no_roll/1, nil, level)

    assert message =~ "+2 CA"
    assert {:ok, next} = change.(w)
    next
  end

  test "bonus action and one slot grant +2 effective AC for ten minutes without changing base AC" do
    {:ok, w} = World.begin_combat(["C", "B"]).(world())
    {:ok, w} = World.set_current_combatant("C").(w)
    next = cast(w)
    assert next.characters["A"].ac == 12
    assert Effects.effective_ac(next.characters["A"]) == 14
    assert next.characters["C"].concentrating == "shield of faith"
    assert next.effect_expiries["C"]["concentrating"] == 600
    assert next.spell_slots["C"] == %{1 => 3, 2 => 2}
    assert next.turn_state["C"]["bonus"]
    refute next.turn_state["C"]["action"]
    assert {:error, _} = Actions.spell(next, "C", "shield of faith", "C", &no_roll/1)
    assert {:error, _} = Actions.spell(next, "C", "cure wounds", "C", &no_roll/1)
    assert {:ok, _, _} = Actions.spell(next, "C", "fire bolt", "B", seq([{20, 1}]))
  end

  test "weapon and spell attacks miss against the same raised AC and log its value" do
    w = cast(world())

    for kind <- [:weapon, :spell] do
      r = seq([{20, 11}])
      {:ok, rec} = RollLog.start()
      log = %RollLog{base: r, recorder: rec}

      result =
        if kind == :weapon,
          do: Actions.attack(w, "B", "A", "sword", r, :normal, log),
          else: Actions.spell(w, "B", "fire bolt", "A", r, log)

      assert {:ok, msg, change} = result
      assert msg =~ "CA 14"
      assert {:ok, next} = change.(w)
      assert next.characters["A"].hp == 30
      [entry] = RollLog.entries(rec)
      assert entry.against == ["ac", 14]
      assert entry.outcome == :miss
      RollLog.stop(rec)
      assert Process.get(:faith_rolls) == []
    end
  end

  test "natural 20 still hits and natural 1 still misses" do
    w = cast(world())
    {:ok, _, hit} = Actions.attack(w, "B", "A", "sword", seq([{20, 20}, {6, 2}, {6, 3}]))
    {:ok, next} = hit.(w)
    assert next.characters["A"].hp == 25
    {:ok, _, miss} = Actions.attack(w, "B", "A", "sword", seq([{20, 1}]))
    {:ok, next} = miss.(w)
    assert next.characters["A"].hp == 30
  end

  test "Defense stacks with Faith and is included for spell attacks too" do
    w = put_in(world().characters["A"].fighting_style, "defense") |> cast()
    assert Effects.effective_ac(w.characters["A"]) == 15
    {:ok, msg, change} = Actions.spell(w, "B", "fire bolt", "A", seq([{20, 12}]))
    assert msg =~ "CA 15"
    {:ok, next} = change.(w)
    assert next.characters["A"].hp == 30
    {:ok, next} = World.clear_concentration("C").(next)
    assert Effects.effective_ac(next.characters["A"]) == 13
  end

  test "self cast, higher slot and recast preserve base AC and replace the target" do
    w = cast(world(), "C", 2)
    assert w.spell_slots["C"] == %{1 => 4, 2 => 1}
    assert Effects.effective_ac(w.characters["C"]) == 14
    {:ok, w} = World.advance_time(590).(w)
    w = cast(w)
    assert Effects.effective_ac(w.characters["C"]) == 12
    assert Effects.effective_ac(w.characters["A"]) == 14
    assert w.effect_expiries["C"]["concentrating"] == 1190
    assert w.characters["C"].ac == 12
  end

  test "multiple sources do not stack and dropping one preserves the other" do
    w = cast(world())
    other = %{w.characters["C"] | name: "Other", concentrating: nil}
    w = %{w | characters: Map.put(w.characters, "Other", other)}
    {:ok, _, change} = Actions.spell(w, "Other", "shield of faith", "A", &no_roll/1)
    {:ok, w} = change.(w)
    assert Effects.effective_ac(w.characters["A"]) == 14
    {:ok, w} = World.clear_concentration("C").(w)
    assert Effects.effective_ac(w.characters["A"]) == 14
    {:ok, w} = World.clear_concentration("Other").(w)
    assert Effects.effective_ac(w.characters["A"]) == 12
  end

  test "damage to the recipient does not test the caster's concentration" do
    w = cast(world())
    {:ok, next} = World.apply_damage("A", 3, "fire", &no_roll/1).(w)
    assert next.characters["A"].hp == 27
    assert Effects.effective_ac(next.characters["A"]) == 14
    assert next.characters["C"].concentrating == "shield of faith"
  end

  test "failed caster concentration, incapacitation, rage and falling to zero remove protection" do
    w = cast(world())

    for change <- [
          World.apply_damage("C", 1, "fire", fn 20 -> 1 end),
          World.apply_condition("C", "stunned"),
          World.set_raging("C", true),
          World.apply_damage("C", 30, "fire", &no_roll/1)
        ] do
      {:ok, next} = change.(w)
      assert Effects.effective_ac(next.characters["A"]) == 12
      assert next.characters["A"].ac == 12
    end
  end

  test "switching Bless and Faith clears the previous effect on all its targets" do
    w = world()
    {:ok, _, bless} = Actions.spell(w, "C", "bless", "A", &no_roll/1, nil, 1, ["C"])
    {:ok, w} = bless.(w)
    w = cast(w)
    refute Effects.blessed?(w.characters["A"])
    refute Effects.blessed?(w.characters["C"])
    {:ok, _, bless} = Actions.spell(w, "C", "bless", "C", &no_roll/1)
    {:ok, w} = bless.(w)
    assert Effects.effective_ac(w.characters["A"]) == 12
    assert Effects.blessed?(w.characters["C"])
  end

  test "JSON round-trip expires at the original 600-second deadline" do
    w = cast(world())
    {:ok, w} = World.advance_time(599).(w)
    w = w |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert Effects.effective_ac(w.characters["A"]) == 14
    {:ok, next} = World.advance_time(1).(w)
    assert Effects.effective_ac(next.characters["A"]) == 12
    assert next.characters["C"].concentrating == nil
  end

  test "invalid and dead targets reject; downed targets are legal; additional_targets is Bless-only" do
    w = world()
    assert {:error, _} = Actions.spell(w, "C", "shield of faith", "missing", &no_roll/1)
    assert {:error, _} = Actions.spell(w, "C", "shield of faith", "A", &no_roll/1, nil, 1, ["B"])
    dead = update_in(w.characters["A"], &%{&1 | hp: 0, death_saves: %{fails: 3, successes: 0}})
    assert {:error, _} = Actions.spell(dead, "C", "shield of faith", "A", &no_roll/1)
    downed = put_in(w.characters["A"].hp, 0) |> cast()
    assert Effects.effective_ac(downed.characters["A"]) == 14
    assert downed.characters["A"].hp == 0
  end

  test "prepared casts revalidate a deleted target and do not spend the slot" do
    w = world()
    {:ok, _, change} = Actions.spell(w, "C", "shield of faith", "A", &no_roll/1)
    altered = %{w | characters: Map.delete(w.characters, "A")}
    assert {:error, _} = change.(altered)
    assert altered.spell_slots["C"][1] == 4
  end

  test "Twinned protects both targets under one slot and concentration and consumes the option" do
    w = put_in(world().characters["C"].metamagic, %{option: "twinned", target: "B"})
    w = cast(w)
    assert Effects.effective_ac(w.characters["A"]) == 14
    assert Effects.effective_ac(w.characters["B"]) == 14
    assert w.spell_slots["C"][1] == 3
    assert w.characters["C"].metamagic == nil
    {:ok, next} = World.clear_concentration("C").(w)
    assert Effects.effective_ac(next.characters["A"]) == 12
    assert Effects.effective_ac(next.characters["B"]) == 12
  end

  test "Twinned duplicate targets fail atomically" do
    w = put_in(world().characters["C"].metamagic, %{option: "twinned", target: "A"})
    assert {:error, _} = Actions.spell(w, "C", "shield of faith", "A", &no_roll/1)
    assert w.spell_slots["C"][1] == 4
    assert w.characters["C"].metamagic != nil
  end

  test "Extra Attack recalculates self-protection after losing concentration and reports each AC" do
    w = world() |> cast("C")
    w = update_in(w.characters["B"], &%{&1 | class: "fighter", level: 5})
    r = seq([{20, 11}, {6, 2}, {20, 1}, {20, 10}, {6, 2}])
    {:ok, message, change} = Actions.attack(w, "B", "C", "sword", r)
    {:ok, next} = change.(w)
    assert next.characters["C"].hp == 26
    assert message =~ "vs CA 14"
    assert message =~ "vs CA 12"
    assert Effects.effective_ac(next.characters["C"]) == 12
    assert Process.get(:faith_rolls) == []
  end

  test "an attack prepared as a miss cannot be applied after protection changes" do
    w = cast(world())
    {:ok, _, weapon} = Actions.attack(w, "B", "A", "sword", seq([{20, 11}]))
    {:ok, _, spell} = Actions.spell(w, "B", "fire bolt", "A", seq([{20, 11}]))
    {:ok, altered} = World.clear_concentration("C").(w)
    assert {:error, _} = weapon.(altered)
    assert {:error, _} = spell.(altered)
  end

  test "legacy concentration and manually named conditions grant no automatic protection" do
    {:ok, w} = World.set_concentration("C", "shield of faith").(world())
    {:ok, w} = World.apply_condition("A", "shield_of_faith").(w)
    assert Effects.effective_ac(w.characters["A"]) == 12
    assert Effects.effective_ac(w.characters["C"]) == 12
  end
end
