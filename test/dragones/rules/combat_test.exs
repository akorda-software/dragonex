defmodule Dragones.Rules.CombatTest do
  @moduledoc """
  Deterministic combat math. Every roll comes from a fixed roller, so each
  assertion is a single expected value (no randomness).
  """

  use ExUnit.Case, async: true

  alias Dragones.{Archetypes, Rules.Combat}

  defp always(n), do: fn _sides -> n end

  defp weapon(character, name),
    do: Enum.find(character.weapons, &(&1.name == name)) || raise("no weapon #{name}")

  defp spell(character, name),
    do: Enum.find(character.spells, &(&1.name == name)) || raise("no spell #{name}")

  describe "roll_initiative/2" do
    test "is d20 + dex modifier (rogue dex 16 -> +3)" do
      rogue = Archetypes.rogue()
      assert {10, 13} = Combat.roll_initiative(rogue, always(10))
    end
  end

  describe "attack_roll/4" do
    setup do
      {:ok, fighter: Archetypes.fighter(), rogue: Archetypes.rogue()}
    end

    test "nat 20 is a critical hit regardless of AC", %{fighter: f} do
      assert {:crit, 20, _total} =
               Combat.attack_roll(f, weapon(f, "longsword"), 30, always(20))
    end

    test "nat 1 is an automatic miss regardless of AC", %{fighter: f} do
      assert {:miss, 1, _total} = Combat.attack_roll(f, weapon(f, "longsword"), 5, always(1))
    end

    test "fighter hits when d20+prof+str meets the AC", %{fighter: f} do
      # str 16 (+3) + prof (+2) => +5; d20 10 -> total 15.
      assert {:hit, 10, 15} = Combat.attack_roll(f, weapon(f, "longsword"), 15, always(10))
    end

    test "fighter misses when the total is below the AC", %{fighter: f} do
      assert {:miss, 9, 14} = Combat.attack_roll(f, weapon(f, "longsword"), 15, always(9))
    end

    test "finesse weapon uses the higher of str/dex (rogue dex +3)", %{rogue: r} do
      # shortsword finesse -> dex (+3) + prof (+2) => +5; d20 10 -> 15.
      assert {:hit, 10, 15} = Combat.attack_roll(r, weapon(r, "shortsword"), 14, always(10))
    end

    test "ranged weapon always uses dex", %{rogue: r} do
      # shortbow ranged -> dex (+3) + prof (+2) => +5; d20 10 -> 15.
      assert {:hit, 10, 15} = Combat.attack_roll(r, weapon(r, "shortbow"), 15, always(10))
    end
  end

  describe "damage_roll/4" do
    setup do
      {:ok, fighter: Archetypes.fighter()}
    end

    test "normal hit: weapon dice + ability mod (longsword d8, str +3)", %{fighter: f} do
      # roller always 5 -> 5 + 3 = 8.
      assert Combat.damage_roll(f, weapon(f, "longsword"), :hit, always(5)) == 8
    end

    test "crit doubles the dice, NOT the ability mod", %{fighter: f} do
      # 2d8 with roller 5 -> 5+5 = 10, +3 str = 13.
      assert Combat.damage_roll(f, weapon(f, "longsword"), :crit, always(5)) == 13
    end
  end

  describe "spells" do
    setup do
      {:ok, wizard: Archetypes.wizard(), fighter: Archetypes.fighter()}
    end

    test "save DC is 8 + prof + casting mod (wizard int 16 -> 13)", %{wizard: w} do
      assert Combat.spell_save_dc(w, spell(w, "firebolt")) == 13
    end

    test "spell attack bonus is prof + casting mod (wizard -> +5)", %{wizard: w} do
      assert Combat.spell_attack_bonus(w, spell(w, "firebolt")) == 5
    end

    test "saving throw succeeds when total meets the DC", %{fighter: f} do
      # dex 12 (+1), not proficient. d20 10 -> 11 vs dc 13 -> fail.
      assert {10, 11, false} = Combat.saving_throw(f, :dex, 13, always(10))
      # d20 12 -> 13 vs dc 13 -> success.
      assert {12, 13, true} = Combat.saving_throw(f, :dex, 13, always(12))
    end

    test "save proficiency adds the proficiency bonus", %{fighter: f} do
      # str save proficient: str 16 (+3) + prof (+2); d20 10 -> 15 vs dc 15.
      assert {10, 15, true} = Combat.saving_throw(f, :str, 15, always(10))
    end
  end

  describe "death_save/1" do
    test "nat 20 revives (no fail, no success to track)" do
      assert {:revive, 20, 0, 0} = Combat.death_save(always(20))
    end

    test "nat 1 counts as two fails" do
      assert {:crit_fail, 1, 2, 0} = Combat.death_save(always(1))
    end

    test "2-9 is one fail" do
      assert {:fail, 7, 1, 0} = Combat.death_save(always(7))
    end

    test "10-19 is one success" do
      assert {:success, 10, 0, 1} = Combat.death_save(always(10))
      assert {:success, 15, 0, 1} = Combat.death_save(always(15))
    end
  end
end
