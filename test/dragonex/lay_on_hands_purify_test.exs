defmodule Dragonex.LayOnHandsPurifyTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, World}

  defp world do
    c =
      Character.new(
        name: "C",
        class: "paladin",
        level: 4,
        hp: 20,
        max_hp: 20,
        lay_on_hands_pool: 20
      )

    t = Character.new(name: "T", hp: 5, max_hp: 20, temp_hp: 3)
    w = World.new(characters: %{"C" => c, "T" => t})
    {:ok, w} = World.apply_condition("T", "poisoned", 60).(w)
    {:ok, w} = World.apply_condition("T", "diseased", 120).(w)
    w
  end

  defp purify(w, amount \\ 0, conditions \\ ["poisoned"], target \\ "T"),
    do: Actions.lay_on_hands(w, "C", target, amount, conditions)

  for condition <- ~w(poisoned diseased) do
    test "purifying #{condition} costs five and preserves HP, temp HP and other effects" do
      w = world()
      {:ok, _, change} = purify(w, 0, [unquote(condition)])
      {:ok, next} = change.(w)
      assert next.characters["C"].lay_on_hands_pool == 15
      assert next.characters["T"].hp == 5
      assert next.characters["T"].temp_hp == 3

      assert Character.condition_names(next.characters["T"]) ==
               ["poisoned", "diseased"] -- [unquote(condition)]

      refute Map.has_key?(next.effect_expiries["T"], "condition:" <> unquote(condition))
      other = if unquote(condition) == "poisoned", do: "diseased", else: "poisoned"

      assert next.effect_expiries["T"]["condition:" <> other] ==
               w.effect_expiries["T"]["condition:" <> other]
    end
  end

  test "both conditions and healing share one action and spend the summed cost" do
    {:ok, w} = World.begin_combat(["C", "T"]).(world())
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, w} = World.set_concentration("C", "bless").(w)
    {:ok, msg, change} = purify(w, 7, ["poisoned", "diseased"])
    {:ok, next} = change.(w)
    assert msg =~ "17 puntos"
    assert next.characters["C"].lay_on_hands_pool == 3
    assert next.characters["T"].hp == 12
    assert next.characters["T"].conditions == []
    assert next.characters["C"].concentrating == "bless"
    assert next.turn_state["C"]["action"]
    refute next.turn_state["C"]["bonus"]
    assert {:error, _} = Actions.lay_on_hands(next, "C", "T", 1)
  end

  test "healing is capped and spends only actual HP plus purification; full HP is valid" do
    w = put_in(world().characters["T"].hp, 18)
    {:ok, _, change} = purify(w, 8)
    {:ok, next} = change.(w)
    assert next.characters["T"].hp == 20
    assert next.characters["C"].lay_on_hands_pool == 13
    {:ok, _, change} = purify(next, 0, ["diseased"])
    {:ok, next} = change.(next)
    assert next.characters["C"].lay_on_hands_pool == 8
    assert next.characters["T"].hp == 20
  end

  test "purification at zero HP does not stabilize; combined healing clears death saves" do
    w = put_in(world().characters["T"].hp, 0)
    w = put_in(w.characters["T"].death_saves, %{successes: 1, fails: 2})
    {:ok, _, change} = purify(w)
    {:ok, next} = change.(w)
    assert next.characters["T"].hp == 0
    assert next.characters["T"].death_saves == %{successes: 1, fails: 2}
    {:ok, _, change} = purify(w, 1)
    {:ok, next} = change.(w)
    assert next.characters["T"].hp == 1
    assert next.characters["T"].death_saves == %{successes: 0, fails: 0}
  end

  test "self purification preserves unrelated state and long rest restores the pool" do
    w = put_in(world().characters["C"].conditions, ["poisoned"])
    {:ok, _, change} = purify(w, 0, ["poisoned"], "C")
    {:ok, next} = change.(w)
    assert next.characters["C"].conditions == []
    assert next.characters["C"].lay_on_hands_pool == 15
    {:ok, _, rest} = Actions.long_rest(next, "C")
    {:ok, rested} = rest.(next)
    assert rested.characters["C"].lay_on_hands_pool == 20
  end

  test "invalid selections, amounts and insufficient total pool reject" do
    for conditions <- [
          ["blinded"],
          ["poisoned", "poisoned"],
          ["poisoned", "cursed"],
          "poisoned",
          %{},
          [nil]
        ] do
      assert {:error, _} = purify(world(), 0, conditions)
    end

    for amount <- [-1, 2.5, "5", nil, 16] do
      assert {:error, _} = purify(world(), amount)
    end

    assert {:error, _} = purify(put_in(world().characters["C"].lay_on_hands_pool, 4))
    assert {:error, _} = purify(put_in(world().characters["T"].conditions, []))
    assert {:error, _} = purify(world(), 0, [])
  end

  test "actor and recipient restrictions are enforced" do
    for race <- ["undead", "construct"] do
      assert {:error, _} = purify(put_in(world().characters["T"].race, race))
    end

    assert {:error, _} =
             purify(put_in(world().characters["T"].death_saves, %{successes: 0, fails: 3}))

    assert {:error, _} = purify(put_in(world().characters["C"].class, "cleric"))
    assert {:error, _} = purify(put_in(world().characters["C"].hp, 0))
    assert {:error, _} = purify(put_in(world().characters["C"].conditions, ["paralyzed"]))
    assert {:error, _} = purify(world(), 0, ["poisoned"], "missing")
  end

  test "stale resources, HP, condition and expiry reject prepared changes" do
    w = world()
    {:ok, _, change} = purify(w)
    assert {:error, _} = change.(put_in(w.characters["C"].lay_on_hands_pool, 19))
    assert {:error, _} = change.(put_in(w.characters["T"].hp, 4))
    assert {:error, _} = change.(put_in(w.characters["T"].conditions, []))
    assert {:error, _} = change.(put_in(w.effect_expiries["T"]["condition:poisoned"], 90))
  end

  test "old healing and empty selector remain compatible; Codec retains purification" do
    w = world()
    {:ok, _, old} = Actions.lay_on_hands(w, "C", "T", 5)
    {:ok, _, empty} = Actions.lay_on_hands(w, "C", "T", 5, [])
    assert old.(w) == empty.(w)
    {:ok, _, change} = purify(w)
    {:ok, next} = change.(w)
    loaded = next |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert loaded.characters["C"].lay_on_hands_pool == 15
    assert Character.condition_names(loaded.characters["T"]) == ["diseased"]
    assert loaded.effect_expiries["T"] == %{"condition:diseased" => 120}
  end
end
