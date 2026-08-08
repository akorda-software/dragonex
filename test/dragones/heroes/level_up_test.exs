defmodule Dragones.Heroes.LevelUpTest do
  use ExUnit.Case, async: true

  alias Dragones.{Character, Heroes, Heroes.Progression, Item}

  describe "apply_level_up/2" do
    test "sube nivel y suma PG (dado medio + CON)" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "fighter", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{})

      assert c2.level == 2
      # fighter d10 → medio 6 + CON mod
      con_mod = div(c.con - 10, 2)
      assert c2.max_hp == c.max_hp + 6 + con_mod
      assert c2.hp == c.hp + 6 + con_mod
    end

    test "aplica ASI a nivel 4 (cap 20)" do
      {:ok, c1} =
        Heroes.build(%{name: "X", race: "human", class: "fighter", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c1, %{})
      {:ok, c3} = Heroes.apply_level_up(c2, %{})
      assert c3.level == 3

      {:ok, c4} = Heroes.apply_level_up(c3, %{asi: %{str: 2}})
      assert c4.level == 4
      assert c4.str == min(20, c3.str + 2)
      assert Progression.asi_at?(c4.level)
    end

    test "no aplica ASI en niveles sin ASI" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "fighter", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{asi: %{str: 2}})
      # nivel 2 no es ASI: la elección se ignora
      assert c2.str == c.str
    end

    test "añade hechizos elegidos" do
      {:ok, c} =
        Heroes.build(%{
          name: "X",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      count_before = length(c.spells)
      {:ok, c2} = Heroes.apply_level_up(c, %{spells_added: ["shield"]})
      assert length(c2.spells) == count_before + 1
      assert Enum.any?(c2.spells, &(&1.name == "shield"))
    end

    test "paladín gana conjuración al subir a L2" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "paladin", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{})
      assert "spellcasting" in c2.class_features
    end

    test "rechaza subir en nivel 20" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "fighter", background: "soldier"})

      c20 = %{c | level: 20}
      assert {:error, _} = Heroes.apply_level_up(c20, %{})
    end

    test "R1: HP retroactivo al subir CON vía ASI (regla 5e)" do
      c =
        Character.new(
          name: "X",
          class: "fighter",
          level: 3,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 28,
          max_hp: 28,
          ac: 11
        )

      {:ok, c4} = Heroes.apply_level_up(c, %{asi: %{con: 2}})

      # old mod +2, new mod +3; dado medio 6; nivel nuevo 6+3=9; retro (3-2)*3=3 (niveles previos) → 28+12=40
      assert c4.con == 16
      assert c4.max_hp == 40
    end

    test "R1b: HP del nivel nuevo incluye el bono racial por nivel (hill dwarf +1)" do
      dwarf =
        Character.new(
          name: "X",
          race: "hill dwarf",
          class: "fighter",
          level: 3,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 28,
          max_hp: 28,
          ac: 11
        )

      {:ok, d4} = Heroes.apply_level_up(dwarf, %{asi: %{str: 2}})
      # fighter d10 avg 6 + con_mod +2 + hill dwarf racial +1 = 9; sin ASI CON, retro 0
      assert d4.max_hp == 28 + 9
    end

    test "R2: AC recalculada al subir DEX sin armadura" do
      c =
        Character.new(
          name: "X",
          class: "fighter",
          level: 3,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 28,
          max_hp: 28,
          ac: 11
        )

      {:ok, c4} = Heroes.apply_level_up(c, %{asi: %{dex: 2}})
      # sin armadura: 10 + mod(14) = 12
      assert c4.dex == 14
      assert c4.ac == 12
    end

    test "V1: rechaza ASI que excede el cupo de puntos" do
      c =
        Character.new(
          name: "X",
          class: "fighter",
          level: 3,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 28,
          max_hp: 28,
          ac: 11
        )

      assert {:error, msg} = Heroes.apply_level_up(c, %{asi: %{str: 3}})
      assert msg =~ "ASI"
    end

    test "R2: AC con armadura ligera sube al subir DEX (dex 14→16)" do
      rogue =
        Character.new(
          name: "X",
          race: "human",
          class: "rogue",
          level: 3,
          str: 10,
          dex: 14,
          con: 12,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 24,
          max_hp: 24,
          ac: 13,
          inventory: [%Item{name: "leather armor", qty: 1, kind: :armor}]
        )

      {:ok, r4} = Heroes.apply_level_up(rogue, %{asi: %{dex: 2}})
      # leather armor: 11 + dex_mod; dex 14(+2)→16(+3) → AC 13→14
      assert r4.dex == 16
      assert r4.ac == 14
    end

    test "R2: AC con armadura pesada ignora el DEX" do
      fighter =
        Character.new(
          name: "X",
          race: "human",
          class: "fighter",
          level: 3,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 28,
          max_hp: 28,
          ac: 16,
          inventory: [%Item{name: "chain mail", qty: 1, kind: :armor}]
        )

      {:ok, f4} = Heroes.apply_level_up(fighter, %{asi: %{dex: 2}})
      # chain mail (heavy) AC fija 16; subir DEX no la cambia
      assert f4.dex == 14
      assert f4.ac == 16
    end
  end
end
