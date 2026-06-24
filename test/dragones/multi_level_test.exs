defmodule Dragones.MultiLevelTest do
  @moduledoc """
  Multi-level HP computation (builder) and the level_up World change.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Character, Heroes, World}

  describe "builder HP progression" do
    test "level 1 fighter (d10, con 15 → +2): HP 12" do
      {:ok, c} = Heroes.build(%{
        name: "Hero", race: "human", class: "fighter", background: "soldier",
        level: 1
      })

      # human con 14+1=15 → +2; d10 max = 10
      assert c.hp == 12
      assert c.max_hp == 12
    end

    test "level 3 fighter: HP 12 + 2*(6+2) = 28" do
      {:ok, c} = Heroes.build(%{
        name: "Hero", race: "human", class: "fighter", background: "soldier",
        level: 3
      })

      # Level 1: 10 + 2 = 12
      # Level 2: +6 + 2 = 8
      # Level 3: +6 + 2 = 8
      assert c.hp == 28
      assert c.max_hp == 28
    end

    test "level 5 wizard: HP scales with d6 + con" do
      {:ok, c} = Heroes.build(%{
        name: "Mage", race: "human", class: "wizard", background: "sage",
        level: 5
      })

      # con 14+1=15 → +2; d6
      # Level 1: 6 + 2 = 8
      # Level 2-5: 4 × (4 + 2) = 24
      assert c.hp == 32
      assert c.level == 5
    end

    test "proficiency bonus increases with level" do
      {:ok, c3} = Heroes.build(%{
        name: "H", race: "human", class: "fighter", background: "soldier", level: 3
      })

      # Level 3 → proficiency 2
      assert Dragones.Rules.Ability.proficiency(c3.level) == 2

      {:ok, c5} = Heroes.build(%{
        name: "H", race: "human", class: "fighter", background: "soldier", level: 5
      })

      # Level 5 → proficiency 3
      assert Dragones.Rules.Ability.proficiency(c5.level) == 3
    end

    test "hill dwarf hp_bonus applies every level" do
      {:ok, c1} = Heroes.build(%{
        name: "Dorin", race: "dwarf", subrace: "hill",
        class: "fighter", background: "soldier", level: 1
      })

      # Level 1: d10(10) + con_mod(16→3) + hill(1) = 14
      assert c1.hp == 14

      {:ok, c3} = Heroes.build(%{
        name: "Dorin", race: "dwarf", subrace: "hill",
        class: "fighter", background: "soldier", level: 3
      })

      # Level 1: 14
      # Level 2: +6 + 3 + 1 = 10
      # Level 3: +6 + 3 + 1 = 10
      assert c3.hp == 34
    end
  end

  describe "World.level_up/1" do
    test "increments level and adds avg HP" do
      fighter = Character.new(
        name: "hero", class: "fighter", level: 1,
        hp: 12, max_hp: 12, ac: 16,
        str: 16, dex: 12, con: 14, int: 10, wis: 10, cha: 10,
        side: "pc"
      )

      {:ok, w} = World.add_character(fighter).(World.new())
      {:ok, w2} = World.level_up("hero").(w)

      hero = w2.characters["hero"]
      assert hero.level == 2
      # Fighter d10: avg = 6, con_mod(14) = +2 → +8 HP
      assert hero.max_hp == 20
      assert hero.hp == 20
    end

    test "refreshes spell slots for casters" do
      wizard = Character.new(
        name: "Lyra", class: "wizard", level: 1,
        hp: 8, max_hp: 8, ac: 10,
        str: 8, dex: 14, con: 14, int: 16, wis: 12, cha: 10,
        side: "pc"
      )

      {:ok, w} = World.add_character(wizard).(World.new())
      w = World.init_spell_slots(w)

      # Exhaust both level-1 slots
      {:ok, w} = World.consume_slot("Lyra", 1).(w)
      {:ok, w} = World.consume_slot("Lyra", 1).(w)
      assert w.spell_slots["Lyra"][1] == 0

      # Level up → slots refresh to level 2 (3×1)
      {:ok, w2} = World.level_up("Lyra").(w)
      assert w2.spell_slots["Lyra"][1] == 3
    end

    test "refuses level 20" do
      hero = Character.new(name: "max", class: "fighter", level: 20, hp: 100, max_hp: 100, side: "pc")
      {:ok, w} = World.add_character(hero).(World.new())

      assert {:error, msg} = World.level_up("max").(w)
      assert msg =~ "max level"
    end
  end
end
