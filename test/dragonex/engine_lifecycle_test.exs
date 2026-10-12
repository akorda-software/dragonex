defmodule Dragonex.EngineLifecycleTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, World}

  defp world(opts \\ []) do
    c = Character.new(Keyword.merge([name: "Hero", class: "fighter", hp: 5, max_hp: 12], opts))
    World.new(characters: %{"Hero" => c})
  end

  defp no_roll(_), do: flunk("an invalid action must not roll dice")

  test "ordinary healing cannot resurrect a dead character at either entry point" do
    w = world(hp: 0, death_saves: %{successes: 0, fails: 3})
    assert {:error, _} = World.heal("Hero", 5).(w)
    assert {:error, _} = Actions.heal(w, "Hero", "1d8", &no_roll/1)
  end

  test "negative healing is rejected instead of bypassing damage rules" do
    assert {:error, _} = World.heal("Hero", -20).(world())
  end

  test "healing rolls with a negative total restore zero HP" do
    w = world()
    {:ok, message, change} = Actions.heal(w, "Hero", "1d4-5", fn _ -> 1 end)
    assert {:ok, ^w} = change.(w)
    assert message =~ "se cura 0 pg"
  end

  test "short rest with negative CON cannot damage the resting character" do
    w = world(con: 1)
    {:ok, message, change} = Actions.short_rest(w, "Hero", fn _ -> 1 end)
    assert {:ok, next} = change.(w)
    assert next.characters["Hero"].hp == 5
    assert message =~ "recupera 0 pg"
  end

  for {label, opts} <- [
        {"conscious", [hp: 5]},
        {"stable", [hp: 0, death_saves: %{successes: 3, fails: 0}]},
        {"dead", [hp: 0, death_saves: %{successes: 0, fails: 3}]}
      ] do
    test "World rejects a death save for a #{label} character" do
      w = world(unquote(Macro.escape(opts)))
      assert {:error, _} = World.apply_death_save("Hero", {:revive, 20, 0, 0}).(w)
    end
  end

  test "zero damage never activates Relentless Endurance or resurrects the dead" do
    for saves <- [%{successes: 0, fails: 0}, %{successes: 0, fails: 3}] do
      w = world(hp: 0, race: "half-orc", death_saves: saves)
      assert {:ok, ^w} = World.apply_damage("Hero", 0).(w)
    end
  end

  test "damage to an already downed half-orc does not activate Relentless Endurance" do
    w = world(hp: 0, race: "half-orc")
    {:ok, next} = World.apply_damage("Hero", 1).(w)
    assert next.characters["Hero"].hp == 0
    refute next.characters["Hero"].relentless_endurance_used
    assert next.characters["Hero"].death_saves.fails == 1
  end

  test "actual reduction to zero still activates Relentless Endurance" do
    w = world(race: "half-orc")
    {:ok, next} = World.apply_damage("Hero", 5).(w)
    assert next.characters["Hero"].hp == 1
    assert next.characters["Hero"].relentless_endurance_used
  end

  test "dropping to zero breaks concentration even through direct World damage" do
    w = world(concentrating: "bless")
    {:ok, next} = World.apply_damage("Hero", 5).(w)
    assert next.characters["Hero"].concentrating == nil
  end

  test "surviving at one HP does not automatically break concentration" do
    w = world(race: "half-orc", concentrating: "bless")
    {:ok, next} = World.apply_damage("Hero", 5, nil, fn _ -> 20 end).(w)
    assert next.characters["Hero"].concentrating == "bless"
  end

  test "Lay on Hands rechecks the pool when a previously prepared change is applied" do
    w = world(class: "paladin", lay_on_hands_pool: 5)
    {:ok, _, change} = Actions.lay_on_hands(w, "Hero", "Hero", 5)
    {:ok, spent} = World.set_lay_on_hands_pool("Hero", 0).(w)
    assert {:error, _} = change.(spent)
    assert {:error, _} = World.lay_on_hands("Hero", "Hero", 6).(w)
  end

  defp healing_world(opts) do
    caster =
      Character.new(
        name: "Cleric",
        class: "cleric",
        hp: 8,
        max_hp: 8,
        wis: 1,
        spells: [
          %Dragonex.Spell{
            name: "cure wounds",
            level: 1,
            kind: :automatic,
            dice: "1d8",
            casting_ability: :wis
          }
        ]
      )

    w = world(opts)

    %{
      w
      | characters: Map.put(w.characters, caster.name, caster),
        spell_slots: %{"Cleric" => %{1 => 1}}
    }
  end

  test "a healing spell with a negative ability modifier heals zero and spends one slot" do
    w = healing_world([])
    {:ok, _, change} = Actions.spell(w, "Cleric", "cure wounds", "Hero", fn _ -> 1 end)
    assert {:ok, next} = change.(w)
    assert next.characters["Hero"].hp == 5
    assert next.spell_slots["Cleric"][1] == 0
  end

  test "a healing spell on the dead is rejected before rolling" do
    w = healing_world(hp: 0, death_saves: %{successes: 0, fails: 3})
    assert {:error, _} = Actions.spell(w, "Cleric", "cure wounds", "Hero", &no_roll/1)
  end

  test "a prepared heal spell cannot resurrect someone who died before application" do
    w = healing_world(hp: 0)
    {:ok, _, change} = Actions.spell(w, "Cleric", "cure wounds", "Hero", fn _ -> 8 end)
    dead = %{w.characters["Hero"] | death_saves: %{successes: 0, fails: 3}}
    w = %{w | characters: Map.put(w.characters, "Hero", dead)}
    assert {:error, _} = change.(w)
    assert w.spell_slots["Cleric"][1] == 1
  end

  test "Lay on Hands rejects a dead target before reporting success" do
    w = world(hp: 0, death_saves: %{successes: 0, fails: 3})

    paladin =
      Character.new(name: "Paladin", class: "paladin", hp: 10, max_hp: 10, lay_on_hands_pool: 5)

    w = %{w | characters: Map.put(w.characters, "Paladin", paladin)}
    assert {:error, _} = Actions.lay_on_hands(w, "Paladin", "Hero", 5)
    assert {:error, _} = World.lay_on_hands("Paladin", "Hero", 5).(w)
  end
end
