defmodule Dragonex.SpareTheDyingTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, PCAgent, World}
  alias Dragonex.Heroes.Spells

  defp world do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 12,
        max_hp: 12,
        spells: [Spells.to_character_spell(Spells.get("spare the dying"), :wis)]
      )

    a = Character.new(name: "A", hp: 0, max_hp: 20, death_saves: %{successes: 1, fails: 2})
    World.new(characters: %{"C" => c, "A" => a}, spell_slots: %{"C" => %{1 => 0}})
  end

  defp no_roll(_), do: flunk("stabilization must not roll")

  test "cantrip stabilizes a dying ally without healing or spending a slot" do
    w = world()
    assert {:ok, msg, change} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)
    assert {:ok, next} = change.(w)
    assert next.characters["A"].hp == 0
    assert next.characters["A"].death_saves == %{successes: 3, fails: 0}
    assert next.spell_slots == w.spell_slots
    assert msg =~ "estable"
    assert {:error, _} = Actions.death_save(next, "A", &no_roll/1)
  end

  test "stable PC instructions request no death save, while dead and dying remain distinct" do
    w = world()
    stable = %{w.characters["A"] | death_saves: %{successes: 3, fails: 0}}
    instruction = PCAgent.instruction("A", stable, w)
    assert instruction =~ "ESTABLE"
    refute instruction =~ "make_death_save("
    assert instruction =~ "NO llames"
    assert PCAgent.instruction("A", w.characters["A"], w) =~ "make_death_save("
    dead = %{stable | death_saves: %{successes: 3, fails: 3}}
    assert PCAgent.instruction("A", dead, w) =~ "MUERTO"
  end

  test "uses caster action, preserves concentration and leaves recipient turn resources alone" do
    {:ok, w} = World.set_concentration("C", "bless").(world())
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, change} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)
    {:ok, next} = change.(w)
    assert next.turn_state["C"]["action"]
    refute next.turn_state["C"]["bonus"]
    assert next.turn_state["A"] == w.turn_state["A"]
    assert next.characters["C"].concentrating == "bless"
    assert next.effect_expiries == w.effect_expiries
    assert {:error, _} = Actions.spell(next, "C", "spare the dying", "A", &no_roll/1)
  end

  test "stable target remains at zero and casting again still consumes an action" do
    w = put_in(world().characters["A"].death_saves, %{successes: 3, fails: 0})
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, change} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)
    {:ok, next} = change.(w)
    assert next.characters["A"] == w.characters["A"]
    assert next.turn_state["C"]["action"]
  end

  test "conditions and temp HP survive stabilization; damage and healing use existing lifecycle" do
    w = world()
    w = put_in(w.characters["A"].conditions, ["unconscious", "poisoned"])
    w = put_in(w.characters["A"].temp_hp, 2)
    {:ok, _, change} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)
    {:ok, next} = change.(w)
    assert next.characters["A"].conditions == ["unconscious", "poisoned"]
    assert next.characters["A"].temp_hp == 2
    loaded = next |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert loaded.characters["A"].death_saves == %{successes: 3, fails: 0}
    {:ok, unchanged} = World.apply_damage("A", 0).(loaded)
    assert unchanged.characters["A"].death_saves == %{successes: 3, fails: 0}
    {:ok, damaged} = World.apply_damage("A", 3).(loaded)
    assert damaged.characters["A"].death_saves == %{successes: 0, fails: 1}
    assert {:ok, _, _} = Actions.death_save(damaged, "A", fn _ -> 10 end)
    {:ok, healed} = World.heal("A", 4).(loaded)
    assert healed.characters["A"].hp == 4
    assert healed.characters["A"].death_saves == %{successes: 0, fails: 0}
  end

  test "invalid targets, upcasting and additional targets fail without spending resources" do
    w = world()

    for changed <- [
          put_in(w.characters["A"].hp, 1),
          put_in(w.characters["A"].death_saves.fails, 3),
          put_in(w.characters["A"].race, "undead"),
          put_in(w.characters["A"].race, "CONSTRUCT")
        ] do
      assert {:error, _} = Actions.spell(changed, "C", "spare the dying", "A", &no_roll/1)
      assert changed.spell_slots == w.spell_slots
      assert changed.turn_state == w.turn_state
    end

    assert {:error, _} = Actions.spell(w, "C", "spare the dying", "missing", &no_roll/1)
    assert {:error, _} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1, nil, 1)

    assert {:error, _} =
             Actions.spell(w, "C", "spare the dying", "A", &no_roll/1, nil, nil, ["C"])
  end

  test "caster cannot stabilize themselves while down or cast while incapacitated" do
    w = world()
    assert {:error, _} = Actions.spell(w, "C", "spare the dying", "C", &no_roll/1)
    down = put_in(w.characters["C"].hp, 0)
    assert {:error, _} = Actions.spell(down, "C", "spare the dying", "C", &no_roll/1)
    stunned = put_in(w.characters["C"].conditions, ["stunned"])
    assert {:error, _} = Actions.spell(stunned, "C", "spare the dying", "A", &no_roll/1)
  end

  test "prepared stabilization rejects changed target, actor or spent action" do
    {:ok, w} = World.begin_combat(["C", "A"]).(world())
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, change} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)

    for changed <- [
          put_in(w.characters["A"].hp, 1),
          put_in(w.characters["A"].death_saves.fails, 3),
          put_in(w.characters["A"].race, "undead"),
          put_in(w.characters["C"].hp, 0),
          put_in(w.turn_state["C"]["action"], true)
        ] do
      assert {:error, _} = change.(changed)
    end
  end

  test "Twinned stabilizes both once and rejects duplicate or invalid second target atomically" do
    w = world()
    w = put_in(w.characters["B"], %{w.characters["A"] | name: "B"})
    w = put_in(w.characters["C"].metamagic, %{option: "twinned", target: "B"})
    {:ok, _, change} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)
    {:ok, next} = change.(w)

    for name <- ["A", "B"] do
      assert next.characters[name].hp == 0
      assert next.characters[name].death_saves == %{successes: 3, fails: 0}
    end

    assert next.characters["C"].metamagic == nil
    assert next.spell_slots == w.spell_slots
    invalid = put_in(w.characters["B"].death_saves.fails, 3)
    assert {:error, _} = Actions.spell(invalid, "C", "spare the dying", "A", &no_roll/1)
    assert {:error, _} = change.(invalid)
    duplicate = put_in(w.characters["C"].metamagic.target, "A")
    assert {:error, _} = Actions.spell(duplicate, "C", "spare the dying", "A", &no_roll/1)
  end

  test "an action cantrip remains legal after a bonus action spell" do
    w = world()
    word = Spells.to_character_spell(Spells.get("healing word"), :wis)
    w = put_in(w.characters["C"].spells, [word | w.characters["C"].spells])
    w = put_in(w.spell_slots["C"][1], 1)
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, heal} = Actions.spell(w, "C", "healing word", "C", fn _ -> 1 end)
    {:ok, w} = heal.(w)
    {:ok, _, stabilize} = Actions.spell(w, "C", "spare the dying", "A", &no_roll/1)
    {:ok, next} = stabilize.(w)
    assert next.characters["A"].death_saves == %{successes: 3, fails: 0}
    assert next.turn_state["C"]["action"] and next.turn_state["C"]["bonus"]
    assert next.spell_slots["C"][1] == 0
  end

  test "World transition revalidates life and zero HP without touching target budget" do
    w = world()
    stabilize = World.stabilize("A")
    assert {:ok, next} = stabilize.(w)
    assert next.turn_state == w.turn_state
    assert next.characters["A"].death_saves == %{successes: 3, fails: 0}
    assert {:error, _} = stabilize.(put_in(w.characters["A"].hp, 1))
    assert {:error, _} = stabilize.(put_in(w.characters["A"].death_saves.fails, 3))
    assert {:error, _} = World.stabilize("missing").(w)
  end
end
