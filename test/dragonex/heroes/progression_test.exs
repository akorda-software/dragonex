defmodule Dragonex.Heroes.ProgressionTest do
  use ExUnit.Case, async: true

  alias Dragonex.Heroes.Progression

  describe "XP / nivel" do
    test "xp_threshold sigue la tabla 5e" do
      assert Progression.xp_threshold(1) == 0
      assert Progression.xp_threshold(2) == 300
      assert Progression.xp_threshold(4) == 2_700
      assert Progression.xp_threshold(20) == 355_000
      assert Progression.xp_threshold(21) == nil
    end

    test "level_for_xp devuelve el nivel correcto" do
      assert Progression.level_for_xp(0) == 1
      assert Progression.level_for_xp(299) == 1
      assert Progression.level_for_xp(300) == 2
      assert Progression.level_for_xp(900) == 3
      assert Progression.level_for_xp(100_000) == 12
      assert Progression.level_for_xp(999_999) == 20
    end

    test "can_level_up? y xp_to_next_level" do
      refute Progression.can_level_up?(1, 0)
      assert Progression.can_level_up?(1, 300)
      assert Progression.xp_to_next_level(1, 0) == 300
      assert Progression.xp_to_next_level(1, 100) == 200
      assert Progression.xp_to_next_level(3, 2_700) == 0
      assert Progression.can_level_up?(20, 999_999) == false
      assert Progression.xp_to_next_level(20, 0) == nil
    end
  end

  describe "ASI" do
    test "asi_levels son 4/8/12/16/19" do
      assert Progression.asi_levels() == [4, 8, 12, 16, 19]
    end

    test "asi_at? marca los niveles correctos" do
      for l <- [4, 8, 12, 16, 19], do: assert(Progression.asi_at?(l))
      for l <- [1, 2, 3, 5, 7, 10, 18, 20], do: refute(Progression.asi_at?(l))
    end

    test "asi_points son 2" do
      assert Progression.asi_points() == 2
    end
  end

  describe "max_spell_level" do
    test "conjurador completo: 2N-1 para nivel N" do
      assert Progression.max_spell_level("wizard", 1) == 1
      assert Progression.max_spell_level("wizard", 3) == 2
      assert Progression.max_spell_level("wizard", 5) == 3
      assert Progression.max_spell_level("wizard", 17) == 9
      assert Progression.max_spell_level("wizard", 20) == 9
    end

    test "medio conjurador: paladín gana conjuros a L2" do
      assert Progression.max_spell_level("paladin", 1) == 0
      assert Progression.max_spell_level("paladin", 2) == 1
      assert Progression.max_spell_level("paladin", 5) == 2
      assert Progression.max_spell_level("ranger", 9) == 3
      assert Progression.max_spell_level("ranger", 17) == 5
    end

    test "no conjurador: 0" do
      assert Progression.max_spell_level("fighter", 5) == 0
    end
  end

  describe "features_at/2" do
    test "paladín gana spellcasting a L2" do
      assert "spellcasting" in Progression.features_at("paladin", 2)
    end

    test "fighter no gana features modeladas a L2" do
      assert Progression.features_at("fighter", 2) == []
    end
  end
end
