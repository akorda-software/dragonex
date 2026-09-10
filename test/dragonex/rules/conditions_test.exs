defmodule Dragonex.Rules.ConditionsTest do
  use ExUnit.Case, async: true

  alias Dragonex.Character
  alias Dragonex.Rules.Conditions

  @cases [
    # {condition, attack_self, melee_vs, ranged_vs, save_str, save_dex, save_wis, check}
    {"poisoned", :disadvantage, :none, :none, :none, :none, :none, :disadvantage},
    {"frightened", :disadvantage, :none, :none, :none, :none, :none, :disadvantage},
    {"blinded", :disadvantage, :advantage, :advantage, :none, :none, :none, :none},
    {"restrained", :disadvantage, :advantage, :advantage, :none, :disadvantage, :none, :none},
    {"prone", :disadvantage, :advantage, :disadvantage, :none, :none, :none, :none},
    {"paralyzed", :none, :advantage, :advantage, :auto_fail, :auto_fail, :none, :none},
    {"stunned", :none, :advantage, :advantage, :auto_fail, :auto_fail, :none, :none},
    {"unconscious", :none, :advantage, :advantage, :auto_fail, :auto_fail, :none, :none},
    {"petrified", :none, :advantage, :advantage, :auto_fail, :auto_fail, :none, :none},
    {"invisible", :advantage, :disadvantage, :disadvantage, :none, :none, :none, :none}
  ]

  defp sheet(names) do
    Character.new(
      name: "c",
      class: "fighter",
      hp: 10,
      max_hp: 10,
      conditions: Enum.map(List.wrap(names), &%{condition: &1})
    )
  end

  defp expected_attack(:none), do: :normal
  defp expected_attack(mode), do: mode

  defp expected_save(:auto_fail), do: :auto_fail
  defp expected_save(:none), do: {:roll, :normal}
  defp expected_save(mode), do: {:roll, mode}

  describe "per-condition mapping (M06)" do
    for {condition, attack_self, melee_vs, ranged_vs, save_str, save_dex, save_wis, check} <-
          @cases do
      test "#{condition}: attack as attacker → #{attack_self}" do
        mode =
          Conditions.attack_mode(sheet(unquote(condition)), sheet([]),
            requested: :normal,
            ranged: false
          )

        assert mode == expected_attack(unquote(attack_self))
      end

      test "#{condition}: melee vs target → #{melee_vs}" do
        mode =
          Conditions.attack_mode(sheet([]), sheet(unquote(condition)),
            requested: :normal,
            ranged: false
          )

        assert mode == expected_attack(unquote(melee_vs))
      end

      test "#{condition}: ranged vs target → #{ranged_vs}" do
        mode =
          Conditions.attack_mode(sheet([]), sheet(unquote(condition)),
            requested: :normal,
            ranged: true
          )

        assert mode == expected_attack(unquote(ranged_vs))
      end

      test "#{condition}: STR save → #{save_str}" do
        assert Conditions.save_mode(sheet(unquote(condition)), :str) ==
                 expected_save(unquote(save_str))
      end

      test "#{condition}: DEX save → #{save_dex}" do
        assert Conditions.save_mode(sheet(unquote(condition)), :dex) ==
                 expected_save(unquote(save_dex))
      end

      test "#{condition}: WIS save → #{save_wis}" do
        assert Conditions.save_mode(sheet(unquote(condition)), :wis) ==
                 expected_save(unquote(save_wis))
      end

      test "#{condition}: ability check → #{check}" do
        assert Conditions.check_mode(sheet(unquote(condition)), :str, :normal) ==
                 expected_attack(unquote(check))
      end
    end
  end

  describe "combine/2 (5e cancellation)" do
    test "advantage + disadvantage = normal" do
      assert Conditions.combine(true, true) == :normal
    end

    test "advantage only" do
      assert Conditions.combine(true, false) == :advantage
    end

    test "disadvantage only" do
      assert Conditions.combine(false, true) == :disadvantage
    end

    test "neither" do
      assert Conditions.combine(false, false) == :normal
    end
  end

  describe "cancellation across sources" do
    test "model advantage + poisoned attacker = normal" do
      assert Conditions.attack_mode(sheet("poisoned"), sheet([]), requested: :advantage) ==
               :normal
    end

    test "model disadvantage + prone melee target = normal" do
      assert Conditions.attack_mode(sheet([]), sheet("prone"),
               requested: :disadvantage,
               ranged: false
             ) == :normal
    end

    test "prone attacker + prone melee target = normal" do
      assert Conditions.attack_mode(sheet("prone"), sheet("prone"), ranged: false) == :normal
    end

    test "poisoned check + model advantage = normal" do
      assert Conditions.check_mode(sheet("poisoned"), :str, :advantage) == :normal
    end

    test "restrained DEX save + model advantage = normal" do
      assert Conditions.save_mode(sheet("restrained"), :dex, :advantage) == {:roll, :normal}
    end

    test "auto-fail ignores requested advantage" do
      assert Conditions.save_mode(sheet("paralyzed"), :str, :advantage) == :auto_fail
    end
  end
end
