defmodule Dragonex.HealSpellTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, World}
  alias Dragonex.Heroes.Spells

  defp world do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        level: 17,
        wis: 20,
        hp: 10,
        max_hp: 200,
        spells: [Spells.to_character_spell(Spells.get("heal"), :wis)]
      )

    a = Character.new(name: "A", hp: 10, max_hp: 200, temp_hp: 9)

    World.new(
      characters: %{"C" => c, "A" => a, "B" => %{a | name: "B"}},
      spell_slots: %{"C" => %{6 => 2, 7 => 1, 8 => 1, 9 => 1}}
    )
  end

  defp no_roll(_), do: flunk("Heal must not roll dice")

  defp prepare(w, target \\ "A", level \\ nil),
    do: Actions.spell(w, "C", "heal", target, &no_roll/1, nil, level)

  defp cast(w, target \\ "A", level \\ nil) do
    assert {:ok, msg, change} = prepare(w, target, level)
    assert {:ok, next} = change.(w)
    {next, msg}
  end

  for {level, amount} <- [{6, 70}, {7, 80}, {8, 90}, {9, 100}] do
    test "slot #{level} heals exactly #{amount} without adding WIS or rolling" do
      w = world()
      {next, msg} = cast(w, "A", unquote(level))
      assert next.characters["A"].hp == 10 + unquote(amount)
      assert next.characters["A"].temp_hp == 9
      assert next.spell_slots["C"][unquote(level)] == w.spell_slots["C"][unquote(level)] - 1
      assert msg =~ "recupera #{unquote(amount)} pg"
      if unquote(level) > 6, do: assert(msg =~ "(nivel #{unquote(level)})")
    end
  end

  test "caps real healing and removes only explicit curable conditions and their timers" do
    w = world() |> put_in([Access.key(:characters), "A", Access.key(:hp)], 197)

    w =
      Enum.reduce(~w(blinded deafened diseased poisoned paralyzed cursed), w, fn condition, acc ->
        {:ok, next} = World.apply_condition("A", condition, 60).(acc)
        next
      end)

    {next, msg} = cast(w)
    assert next.characters["A"].hp == 200
    assert msg =~ "recupera 3 pg"
    assert Character.condition_names(next.characters["A"]) == ~w(poisoned paralyzed cursed)

    assert Map.keys(next.effect_expiries["A"]) |> Enum.sort() ==
             ~w(condition:cursed condition:paralyzed condition:poisoned)

    loaded = next |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert Character.condition_names(loaded.characters["A"]) == ~w(poisoned paralyzed cursed)
    assert loaded.characters["A"].hp == 200
    assert loaded.effect_expiries == next.effect_expiries
  end

  test "condition cleanup handles string and both map representations even at full HP" do
    w = world()
    w = put_in(w.characters["A"].hp, 200)

    w =
      put_in(w.characters["A"].conditions, [
        "blinded",
        %{condition: "deafened"},
        %{"condition" => "diseased"},
        "poisoned"
      ])

    {next, msg} = cast(w)
    assert next.characters["A"].conditions == ["poisoned"]
    assert msg =~ "recupera 0 pg"
    assert next.spell_slots["C"][6] == 1
  end

  test "revives a living downed target and resets death saves without resurrecting" do
    w = world()
    w = put_in(w.characters["A"].hp, 0)
    w = put_in(w.characters["A"].death_saves, %{successes: 1, fails: 2})
    {next, _} = cast(w)
    assert next.characters["A"].hp == 70
    assert next.characters["A"].death_saves == %{successes: 0, fails: 0}
    dead = put_in(w.characters["A"].death_saves.fails, 3)
    assert {:error, msg} = prepare(dead)
    assert msg =~ "no resucita"
  end

  test "one action and slot, self allowed, existing concentration preserved" do
    {:ok, w} = World.set_concentration("C", "bless").(world())
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {next, _} = cast(w, "C")
    assert next.characters["C"].hp == 80
    assert next.characters["C"].concentrating == "bless"
    assert next.effect_expiries["C"]["concentrating"] == w.effect_expiries["C"]["concentrating"]
    assert next.turn_state["C"]["action"]
    refute next.turn_state["C"]["bonus"]
    assert {:error, _} = prepare(next)
  end

  test "invalid target types, levels, missing slots and additional targets are rejected" do
    w = world()

    for race <- ["undead", "construct", "UNDEAD"] do
      assert {:error, _} = prepare(put_in(w.characters["A"].race, race))
    end

    for level <- [5, 10, "7", 6.5] do
      assert {:error, _} = prepare(w, "A", level)
    end

    assert {:error, _} = prepare(w, "missing")
    assert {:error, _} = prepare(put_in(w.spell_slots["C"][6], 0))
    assert {:error, _} = Actions.spell(w, "C", "heal", "A", &no_roll/1, nil, nil, ["B"])
    assert w.spell_slots["C"][6] == 2
  end

  test "Twinned heals two distinct targets once each with one slot and consumes metamagic" do
    w = put_in(world().characters["C"].metamagic, %{option: "twinned", target: "B"})
    {next, _} = cast(w, "A", 7)
    assert next.characters["A"].hp == 90
    assert next.characters["B"].hp == 90
    assert next.spell_slots["C"][7] == 0
    assert next.characters["C"].metamagic == nil
    assert {:error, _} = prepare(put_in(w.characters["B"].race, "construct"))
    assert {:error, _} = prepare(put_in(w.characters["C"].metamagic.target, "A"))
  end

  test "Empowered and Heightened remain armed and self does not consume Twinned" do
    for option <- ["empowered", "heightened", "twinned"] do
      w = put_in(world().characters["C"].metamagic, %{option: option, target: "A"})
      {next, _} = cast(w, "C")
      assert next.characters["C"].metamagic == w.characters["C"].metamagic
      assert next.characters["C"].hp == 80
    end
  end

  test "prepared Heal rejects target changes and cannot spend stale resources" do
    w = world()
    {:ok, _, change} = prepare(w)

    for changed <- [
          put_in(w.characters["A"].hp, 20),
          put_in(w.characters["A"].race, "undead"),
          put_in(w.characters["A"].death_saves.fails, 3),
          put_in(w.characters["A"].conditions, ["blinded"]),
          put_in(w.spell_slots["C"][6], 0),
          put_in(w.characters["C"].conditions, ["stunned"])
        ] do
      assert {:error, _} = change.(changed)
    end
  end
end
