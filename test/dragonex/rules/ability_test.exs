defmodule Dragonex.Rules.AbilityTest do
  use ExUnit.Case, async: true

  alias Dragonex.Rules.Ability

  describe "modifier/1" do
    test "is floor((score - 10) / 2), flooring toward negative" do
      assert Ability.modifier(10) == 0
      assert Ability.modifier(11) == 0
      assert Ability.modifier(12) == 1
      assert Ability.modifier(13) == 1
      assert Ability.modifier(16) == 3
      assert Ability.modifier(20) == 5

      assert Ability.modifier(9) == -1
      assert Ability.modifier(8) == -1
      assert Ability.modifier(1) == -5
    end
  end

  describe "proficiency/1" do
    test "starts at +2 and grows +1 every four levels, capped at +6" do
      assert Ability.proficiency(1) == 2
      assert Ability.proficiency(4) == 2
      assert Ability.proficiency(5) == 3
      assert Ability.proficiency(8) == 3
      assert Ability.proficiency(9) == 4
      assert Ability.proficiency(12) == 4
      assert Ability.proficiency(13) == 5
      assert Ability.proficiency(16) == 5
      assert Ability.proficiency(17) == 6
      assert Ability.proficiency(20) == 6
    end
  end

  describe "parse/1" do
    test "accepts atoms, prefixes and mixed case" do
      assert Ability.parse(:wis) == {:ok, :wis}
      assert Ability.parse("STR") == {:ok, :str}
      assert Ability.parse("dexterity") == {:ok, :dex}
      assert Ability.parse("  Con  ") == {:ok, :con}
    end

    test "rejects unknown tokens instead of defaulting to strength" do
      assert Ability.parse("luck") == :error
      assert Ability.parse("") == :error
      assert Ability.parse(nil) == :error
    end
  end
end
