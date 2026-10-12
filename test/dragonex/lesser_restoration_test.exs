defmodule Dragonex.LesserRestorationTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, World}
  alias Dragonex.Heroes.Spells

  defp world do
    caster =
      Character.new(
        name: "C",
        class: "cleric",
        level: 5,
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("lesser restoration"), :wis)]
      )

    target = Character.new(name: "T", hp: 5, max_hp: 20, conditions: ["poisoned"])

    World.new(
      characters: %{"C" => caster, "T" => target},
      spell_slots: %{"C" => %{2 => 2, 3 => 1}}
    )
  end

  defp cast(w, condition \\ nil, level \\ nil, target \\ "T") do
    Actions.spell(
      w,
      "C",
      "lesser restoration",
      target,
      fn _ -> flunk("no dice") end,
      nil,
      level,
      nil,
      condition
    )
  end

  for condition <- ~w(blinded deafened paralyzed poisoned diseased) do
    test "removes #{condition} and its timer, preserving unrelated effects" do
      w = put_in(world().characters["T"].conditions, ["frightened"])
      {:ok, w} = World.apply_condition("T", unquote(condition), 60).(w)
      {:ok, w} = World.apply_condition("T", "restrained", 120).(w)
      {:ok, msg, change} = cast(w)
      {:ok, next} = change.(w)
      assert msg =~ "elimina #{Dragonex.Terms.condition(unquote(condition), :es)}"

      assert Enum.sort(Character.condition_names(next.characters["T"])) == [
               "frightened",
               "restrained"
             ]

      refute Map.has_key?(next.effect_expiries["T"], "condition:" <> unquote(condition))
      assert next.effect_expiries["T"]["condition:restrained"] == 120
    end
  end

  test "one eligible condition is removed without healing or rolling" do
    w = world()

    assert {:ok, _, change} =
             Actions.spell(w, "C", "lesser restoration", "T", fn _ -> flunk("no dice") end)

    assert {:ok, next} = change.(w)
    assert next.characters["T"].conditions == []
    assert next.characters["T"].hp == 5
    assert next.spell_slots["C"][2] == 1
  end

  test "ambiguous conditions require explicit choice; only that condition is removed" do
    w = put_in(world().characters["T"].conditions, ["poisoned", "blinded", "cursed"])
    assert {:error, message} = cast(w)
    assert message =~ "condition_to_remove"
    {:ok, _, change} = cast(w, "blinded")
    {:ok, next} = change.(w)
    assert next.characters["T"].conditions == ["poisoned", "cursed"]
  end

  test "invalid and absent selections, empty effects and dead targets reject" do
    for selection <- ["cursed", "stunned", "", 4, %{}, "blinded"] do
      assert {:error, _} = cast(world(), selection)
    end

    assert {:error, _} = cast(put_in(world().characters["T"].conditions, []))

    assert {:error, _} =
             cast(put_in(world().characters["T"].death_saves, %{successes: 0, fails: 3}))

    assert {:error, _} = cast(world(), nil, nil, "missing")
  end

  test "upcasting spends the higher slot but removes only one condition, without concentration" do
    w = put_in(world().characters["T"].conditions, ["blinded", "poisoned"])
    {:ok, w} = World.set_concentration("C", "bless").(w)
    {:ok, w} = World.begin_combat(["C", "T"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, msg, change} = cast(w, "poisoned", 3)
    {:ok, next} = change.(w)
    assert msg =~ "(nivel 3)"
    assert next.spell_slots["C"] == %{2 => 2, 3 => 0}
    assert next.characters["T"].conditions == ["blinded"]
    assert next.characters["C"].concentrating == "bless"
    assert next.turn_state["C"]["action"]
    refute next.turn_state["C"]["bonus"]
    assert {:error, _} = cast(next, "blinded")
  end

  test "self, downed living targets, constructs and undead are supported" do
    for race <- ["human", "construct", "undead"] do
      w = put_in(world().characters["T"].race, race)
      w = put_in(w.characters["T"].hp, 0)
      {:ok, _, change} = cast(w)
      {:ok, next} = change.(w)
      assert next.characters["T"].conditions == []
      assert next.characters["T"].hp == 0
      assert next.characters["T"].death_saves == w.characters["T"].death_saves
    end

    w = put_in(world().characters["C"].conditions, ["poisoned"])
    {:ok, _, change} = cast(w, nil, nil, "C")
    {:ok, next} = change.(w)
    assert next.characters["C"].conditions == []
  end

  test "Twinned resolves one eligible condition per target and consumes metamagic" do
    w =
      put_in(
        world().characters["E"],
        Character.new(name: "E", hp: 20, max_hp: 20, conditions: ["blinded"])
      )

    w = put_in(w.characters["C"].metamagic, %{option: "twinned", target: "E"})
    {:ok, _, change} = cast(w)
    {:ok, next} = change.(w)
    assert next.characters["E"].conditions == []
    assert next.characters["T"].conditions == []
    assert next.characters["C"].metamagic == nil
    assert next.spell_slots["C"][2] == 1
    assert {:error, _} = cast(w, "poisoned")
    w = put_in(w.characters["C"].metamagic.target, "T")
    assert {:error, _} = cast(w)
  end

  test "Empowered and Heightened stay armed" do
    for option <- ["empowered", "heightened"] do
      w = put_in(world().characters["C"].metamagic, %{option: option, target: "T"})
      {:ok, _, change} = cast(w)
      {:ok, next} = change.(w)
      assert next.characters["C"].metamagic == w.characters["C"].metamagic
    end
  end

  test "stale target, condition deadline and depleted slot reject prepared results" do
    {:ok, w} = World.apply_condition("T", "poisoned", 60).(world())
    {:ok, _, change} = cast(w)
    assert {:error, _} = change.(put_in(w.characters["T"].hp, 4))
    assert {:error, _} = change.(put_in(w.effect_expiries["T"]["condition:poisoned"], 120))
    assert {:error, _} = change.(put_in(w.spell_slots["C"][2], 0))
    assert {:error, _} = change.(put_in(w.characters["C"].hp, 0))
  end

  test "invalid levels, additional targets and wrong spell selector reject" do
    for level <- [1, 10, "2", 2.5, 4] do
      assert {:error, _} = cast(world(), nil, level)
    end

    assert {:error, _} =
             Actions.spell(
               world(),
               "C",
               "lesser restoration",
               "T",
               fn _ -> flunk("no dice") end,
               nil,
               nil,
               ["C"]
             )

    w =
      put_in(world().characters["C"].spells, [
        Spells.to_character_spell(Spells.get("cure wounds"), :wis)
      ])

    assert {:error, _} =
             Actions.spell(
               w,
               "C",
               "cure wounds",
               "T",
               fn _ -> flunk("no dice") end,
               nil,
               2,
               nil,
               "poisoned"
             )
  end

  test "JSON roundtrip retains cleanup and unrelated deadline" do
    {:ok, w} = World.apply_condition("T", "poisoned", 60).(world())
    {:ok, w} = World.apply_condition("T", "blinded", 120).(w)
    {:ok, _, change} = cast(w, "poisoned")
    {:ok, next} = change.(w)
    loaded = next |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert Character.condition_names(loaded.characters["T"]) == ["blinded"]
    refute Map.has_key?(loaded.effect_expiries["T"], "condition:poisoned")
    assert loaded.effect_expiries["T"]["condition:blinded"] == 120
  end
end
