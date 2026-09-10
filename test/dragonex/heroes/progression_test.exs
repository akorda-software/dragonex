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

    test "warlock: nivel de pacto, cap 5" do
      assert Progression.max_spell_level("warlock", 1) == 1
      assert Progression.max_spell_level("warlock", 5) == 3
      assert Progression.max_spell_level("warlock", 11) == 5
      assert Progression.max_spell_level("warlock", 17) == 5
      assert Progression.max_spell_level("warlock", 20) == 5
    end
  end

  describe "features_at/2" do
    test "paladín gana spellcasting a L2" do
      assert "spellcasting" in Progression.features_at("paladin", 2)
    end

    test "fighter no gana features modeladas a L2" do
      assert Progression.features_at("fighter", 2) == []
    end

    test "L5 marciales ganan extra_attack" do
      for class <- ~w(fighter barbarian paladin ranger monk) do
        assert Progression.features_at(class, 5) == ["extra_attack"]
      end
    end

    test "L5 no marciales y L3/L11 marciales no añaden extra_attack" do
      assert Progression.features_at("wizard", 5) == []
      assert Progression.features_at("rogue", 5) == []
      assert Progression.features_at("fighter", 3) == []
      assert Progression.features_at("fighter", 11) == []
    end
  end

  describe "attack_count/2" do
    test "fighter escala 1/2/3/4" do
      assert Progression.attack_count("fighter", 1) == 1
      assert Progression.attack_count("fighter", 4) == 1
      assert Progression.attack_count("fighter", 5) == 2
      assert Progression.attack_count("fighter", 10) == 2
      assert Progression.attack_count("fighter", 11) == 3
      assert Progression.attack_count("fighter", 19) == 3
      assert Progression.attack_count("fighter", 20) == 4
    end

    test "bárbaro paladín ranger monje: 2 a L5+" do
      for class <- ~w(barbarian paladin ranger monk) do
        assert Progression.attack_count(class, 4) == 1
        assert Progression.attack_count(class, 5) == 2
        assert Progression.attack_count(class, 20) == 2
      end
    end

    test "resto siempre 1" do
      for class <- ~w(wizard rogue warlock bard cleric sorcerer druid) do
        assert Progression.attack_count(class, 5) == 1
        assert Progression.attack_count(class, 20) == 1
      end
    end
  end

  describe "sneak_attack_dice/2" do
    test "rogue sigue la tabla 5e" do
      assert Progression.sneak_attack_dice("rogue", 1) == 1
      assert Progression.sneak_attack_dice("rogue", 2) == 1
      assert Progression.sneak_attack_dice(:rogue, 3) == 2
      assert Progression.sneak_attack_dice("rogue", 4) == 2
      assert Progression.sneak_attack_dice("rogue", 5) == 3
      assert Progression.sneak_attack_dice("rogue", 19) == 10
      assert Progression.sneak_attack_dice("rogue", 20) == 10
    end

    test "el resto es 0" do
      for class <-
            ~w(fighter wizard barbarian paladin ranger monk bard cleric sorcerer warlock druid) do
        assert Progression.sneak_attack_dice(class, 1) == 0
        assert Progression.sneak_attack_dice(class, 20) == 0
      end
    end
  end
end
