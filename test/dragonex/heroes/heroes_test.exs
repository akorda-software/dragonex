defmodule Dragonex.HeroesTest do
  @moduledoc """
  The character creator produces valid, SRD-correct level-1 characters for
  every class and race in the catalogue.

  Every stat is derived from 5e rules — HP (hit_die + con_mod), AC (armour +
  dex / unarmoured defence), saving proficiencies (class), weapons (starting
  equipment), spells (casting ability from class). No invented numbers.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Character, Heroes}

  describe "random_draft/0" do
    test "generates complete drafts that build successfully" do
      for _ <- 1..30 do
        draft = Heroes.random_draft()

        scores =
          if draft.score_method == "pointbuy" do
            %{method: :point_buy, scores: draft.pb}
          end

        assert {:ok, character} =
                 Heroes.build(%{
                   name: draft.name,
                   race: draft.race,
                   subrace: draft.subrace,
                   class: draft.class,
                   sex: draft.sex,
                   background: draft.background,
                   scores: scores,
                   spells: draft.spells,
                   equipment_picks: draft.equipment,
                   skills: draft.skills_choice,
                   extra_languages: draft.extra_langs,
                   backstory: draft.backstory
                 })

        assert character.name == draft.name
        assert character.skill_proficiencies != []
        assert is_map(draft.equipment)
      end
    end
  end

  # ============================================================ all classes

  describe "every class builds a valid level-1 character" do
    for class_key <- Dragonex.Heroes.list_classes() do
      @tag class: class_key
      test "#{class_key}: changeset passes and level is 1" do
        {:ok, c} = build_human(unquote(class_key))
        assert passes_changeset?(c)
        assert c.level == 1
        assert c.side == "pc"
      end
    end
  end

  # Human standard-array stats are deterministic per class priority order.
  # array [15,14,13,12,10,8] + human +1 all → final scores.
  describe "human standard-array: derived stats per class" do
    test "barbarian: HP from d12 + con, AC from unarmored defense" do
      {:ok, c} = build_human("barbarian")
      # str=15+1, con=14+1, dex=13+1 → con_mod=+2, dex_mod=+2
      assert c.str == 16 and c.con == 15 and c.dex == 14
      # d12 + con_mod(15)=+2
      assert c.hp == 12 + 2
      assert c.max_hp == c.hp
      # unarmored: 10 + dex + con
      assert c.ac == 10 + 2 + 2
      assert c.saving_proficiencies == ["str", "con"]
    end

    test "wizard: INT primary, spell save DC from INT" do
      {:ok, c} = build_human("wizard")
      # int=15+1=16 → +3, level 1 → prof +2
      assert c.int == 16
      # d6 + con_mod(15)=+2
      assert c.hp == 6 + 2
      # unarmored: 10 + dex_mod(14)=+2
      assert c.ac == 10 + 2

      fire_bolt = find_spell(c, "fire bolt")
      assert fire_bolt.casting_ability == :int
      assert fire_bolt.kind == :attack
      # DC = 8 + prof(2) + int_mod(3) = 13
      assert Dragonex.Rules.Combat.spell_save_dc(c, fire_bolt) == 13
    end

    test "fighter: chain mail + shield → AC 18" do
      {:ok, c} = build_human("fighter")
      # chain_mail(16) + shield(2)
      assert c.ac == 18
      # d10 + con_mod(15)=+2
      assert c.hp == 10 + 2
      assert [%{name: "longsword"}, %{name: "light crossbow"} | _] = c.weapons
      assert hd(c.weapons).attack_ability == :str
    end

    test "monk: unarmored defense uses DEX + WIS" do
      {:ok, c} = build_human("monk")
      # dex=15+1=16→+3, wis=14+1=15→+2
      # 15
      assert c.ac == 10 + 3 + 2
      # d8 + con_mod(14)=+2
      assert c.hp == 8 + 2
    end

    test "cleric: scale mail + shield → AC 17" do
      {:ok, c} = build_human("cleric")
      # scale_mail(14) + min(dex_mod, 2) + shield(2); dex=12+1=13→+1
      # 17
      assert c.ac == 14 + 1 + 2
      assert c.saving_proficiencies == ["wis", "cha"]
    end

    test "rogue: leather armor + high DEX → AC 14" do
      {:ok, c} = build_human("rogue")
      # dex=15+1=16→+3; leather(11) + dex_mod(3) = 14
      assert c.ac == 14
      # finesse weapon
      rapier = find_weapon(c, "rapier")
      assert rapier.finesse == true
      assert rapier.attack_ability == :str
    end

    test "sorcerer: no armor, low HP" do
      {:ok, c} = build_human("sorcerer")
      # d6 + con_mod(15)=+2
      assert c.hp == 6 + 2
      # 10 + dex_mod(14)=+2
      assert c.ac == 10 + 2
    end

    test "paladin: chain mail + shield → AC 18" do
      {:ok, c} = build_human("paladin")
      assert c.ac == 18
      assert c.saving_proficiencies == ["wis", "cha"]
    end

    test "ranger: scale mail, DEX primary" do
      {:ok, c} = build_human("ranger")
      # dex=15+1=16→+3; scale_mail(14) + min(3,2) = 16
      assert c.ac == 16
      assert c.saving_proficiencies == ["str", "dex"]
    end

    test "bard: leather armor, CHA caster" do
      {:ok, c} = build_human("bard")
      # cha=15+1=16→+3; leather(11) + dex_mod(15)=+2 → 13
      assert c.ac == 13
      vm = find_spell(c, "vicious mockery")
      assert vm.casting_ability == :cha
      assert vm.save_ability == :wis
    end

    test "druid: leather + shield, WIS caster" do
      {:ok, c} = build_human("druid")
      # leather(11) + dex_mod(14)=+2 + shield(2) = 15
      assert c.ac == 15
      pf = find_spell(c, "produce flame")
      assert pf.casting_ability == :wis
      assert pf.kind == :attack
    end

    test "warlock: leather armor, CHA caster" do
      {:ok, c} = build_human("warlock")
      # leather(11) + dex_mod(14)=+2 = 13
      assert c.ac == 13
      eb = find_spell(c, "eldritch blast")
      assert eb.casting_ability == :cha
      assert eb.dice == "1d10"
    end
  end

  # ============================================================== races

  describe "racial bonuses are applied correctly" do
    test "mountain dwarf: STR +2 and CON +2" do
      {:ok, c} =
        Heroes.build(%{
          name: "Grim",
          race: "dwarf",
          subrace: "mountain",
          class: "fighter",
          background: "soldier"
        })

      # standard array: str=15, con=14 → +mountain: str+2, con+2
      assert c.str == 17 and c.con == 16
    end

    test "hill dwarf: CON +2, WIS +1, hp_bonus +1" do
      {:ok, c} =
        Heroes.build(%{
          name: "Dolgrin",
          race: "dwarf",
          subrace: "hill",
          class: "cleric",
          background: "acolyte"
        })

      # wis=15+1, con=14+2
      assert c.con == 16 and c.wis == 16
      # cleric d8, con_mod(16)=+3, +hill dwarf hp_bonus 1
      assert c.hp == 8 + 3 + 1
    end

    test "high elf: DEX +2, INT +1" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lyra",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      assert c.dex == 15 and c.int == 16
      assert c.speed == 30
    end

    test "wood elf: speed 35" do
      {:ok, c} =
        Heroes.build(%{
          name: "Sylva",
          race: "elf",
          subrace: "wood elf",
          class: "ranger",
          background: "outlander"
        })

      assert c.speed == 35
      # wis=14 base + 1 wood elf
      assert c.wis == 15
    end

    test "halfling: Small size, speed 25, DEX +2" do
      {:ok, c} =
        Heroes.build(%{
          name: "Pip",
          race: "halfling",
          subrace: "lightfoot",
          class: "rogue",
          background: "criminal"
        })

      assert c.speed == 25
      # 15 + 2
      assert c.dex == 17
      # 10 + 1 lightfoot
      assert c.cha == 11
    end

    test "dragonborn: STR +2, CHA +1" do
      {:ok, c} =
        Heroes.build(%{
          name: "Rhogar",
          race: "dragonborn",
          class: "paladin",
          background: "noble"
        })

      # str=15+2, cha=14+1
      assert c.str == 17 and c.cha == 15
      assert c.speed == 30
    end

    test "half-elf: CHA +2, two floating +1 by class priority" do
      {:ok, c} =
        Heroes.build(%{
          name: "Vael",
          race: "half-elf",
          class: "wizard",
          background: "sage"
        })

      # CHA +2, plus +1 to INT and CON (wizard priority, skip CHA)
      # 10 + 2
      assert c.cha == 12
      # 15 + 1
      assert c.int == 16
      # 14 + 1
      assert c.con == 15
    end

    test "half-orc: STR +2, CON +1" do
      {:ok, c} =
        Heroes.build(%{
          name: "Grom",
          race: "half-orc",
          class: "barbarian",
          background: "folk hero"
        })

      assert c.str == 17 and c.con == 15
    end

    test "tiefling: INT +1, CHA +2" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lilith",
          race: "tiefling",
          class: "warlock",
          background: "charlatan"
        })

      assert c.int == 13 and c.cha == 17
    end

    test "gnome forest: INT +2, DEX +1" do
      {:ok, c} =
        Heroes.build(%{
          name: "Fizzle",
          race: "gnome",
          subrace: "forest gnome",
          class: "wizard",
          background: "sage"
        })

      assert c.int == 17 and c.dex == 14
      assert c.speed == 25
    end

    test "subrace passed as race key also works" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lyra",
          race: "high elf",
          class: "wizard",
          background: "sage"
        })

      assert c.int == 16 and c.dex == 15
    end
  end

  # ============================================================ casters

  describe "spellcasting is set up correctly" do
    test "wizard gets 3 cantrips + 6 level-1 spells, all INT-based" do
      {:ok, c} = build_human("wizard")
      cantrips = Enum.filter(c.spells, &(&1.level == 0))
      level1 = Enum.filter(c.spells, &(&1.level == 1))
      assert length(cantrips) == 3
      assert length(level1) == 6
      assert Enum.all?(c.spells, &(&1.casting_ability == :int))
    end

    test "cleric gets 3 cantrips + prepared spells, all WIS-based" do
      {:ok, c} = build_human("cleric")
      cantrips = Enum.filter(c.spells, &(&1.level == 0))
      assert length(cantrips) == 3
      assert Enum.all?(c.spells, &(&1.casting_ability == :wis))
    end

    test "sorcerer gets 4 cantrips + 2 spells, all CHA-based" do
      {:ok, c} = build_human("sorcerer")
      cantrips = Enum.filter(c.spells, &(&1.level == 0))
      level1 = Enum.filter(c.spells, &(&1.level == 1))
      assert length(cantrips) == 4
      assert length(level1) == 2
      assert Enum.all?(c.spells, &(&1.casting_ability == :cha))
    end

    test "non-casters have empty spells list" do
      for class <- ~w(barbarian fighter monk paladin ranger rogue) do
        {:ok, c} = build_human(class)
        assert c.spells == [], "#{class} should have no spells"
      end
    end

    test "user can override default spell picks" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lyra",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage",
          spells: [
            "fire bolt",
            "ray of frost",
            "prestidigitation",
            "magic missile",
            "shield",
            "mage armor",
            "sleep",
            "detect magic",
            "charm person"
          ]
        })

      names = Enum.map(c.spells, & &1.name)
      assert "fire bolt" in names
      assert "ray of frost" in names
      assert "magic missile" in names
      assert "shield" in names
    end
  end

  # ========================================================== weapons

  describe "weapons are set up correctly" do
    test "ranged weapons use DEX" do
      {:ok, c} = build_human("fighter")
      crossbow = find_weapon(c, "light crossbow")
      assert crossbow.ranged == true
      assert crossbow.attack_ability == :dex
    end

    test "finesse weapons carry the finesse flag" do
      {:ok, c} = build_human("rogue")
      rapier = find_weapon(c, "rapier")
      assert rapier.finesse == true
    end

    test "melee weapons default to STR" do
      {:ok, c} = build_human("barbarian")
      greataxe = find_weapon(c, "greataxe")
      assert greataxe.attack_ability == :str
      assert greataxe.finesse == false
      assert greataxe.ranged == false
    end
  end

  # ====================================================== ability methods

  describe "ability score generation" do
    test "standard array auto-assigns by class priority" do
      {:ok, c} = build_human("wizard")
      # priority: int > con > dex > wis > cha > str
      # array sorted desc: 15,14,13,12,10,8 + human +1
      assert c.int == 16 and c.con == 15 and c.dex == 14
      assert c.wis == 13 and c.cha == 11 and c.str == 9
    end

    test "explicit scores are accepted" do
      {:ok, c} =
        Heroes.build(%{
          name: "X",
          race: "human",
          class: "fighter",
          background: "soldier",
          scores: %{str: 15, dex: 14, con: 14, int: 10, wis: 10, cha: 10}
        })

      # + human +1
      assert c.str == 16 and c.con == 15
    end

    test "point buy validates the 27-point budget" do
      {:ok, c} =
        Heroes.build(%{
          name: "X",
          race: "human",
          class: "fighter",
          background: "soldier",
          scores: %{
            method: :point_buy,
            scores: %{str: 15, dex: 14, con: 15, int: 8, wis: 10, cha: 8}
          }
        })

      # 15 + 1 human
      assert c.str == 16
    end

    test "point buy rejects wrong budget" do
      # 3×15 (27) + 9 (1) = 28, exceeds the 27-point budget
      assert {:error, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "fighter",
                 background: "soldier",
                 scores: %{
                   method: :point_buy,
                   scores: %{str: 15, dex: 15, con: 15, int: 9, wis: 8, cha: 8}
                 }
               })
    end
  end

  # ============================================================ helpers

  defp build_human(class) do
    Heroes.build(%{name: "Test", race: "human", class: class, background: "soldier"})
  end

  defp passes_changeset?(%Character{} = c) do
    attrs = c |> Map.from_struct() |> Map.delete(:__meta__)
    Character.changeset(%Character{}, attrs).valid?
  end

  defp find_weapon(c, name), do: Enum.find(c.weapons, &(&1.name == name))
  defp find_spell(c, name), do: Enum.find(c.spells, &(&1.name == name))
end
