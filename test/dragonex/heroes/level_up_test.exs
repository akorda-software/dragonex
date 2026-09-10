defmodule Dragonex.Heroes.LevelUpTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Character, Heroes, Heroes.Progression, Item}

  describe "apply_level_up/2" do
    test "sube nivel y suma PG (dado medio + CON)" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "fighter", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{})

      assert c2.level == 2
      # fighter d10 → medio 6 + CON mod
      con_mod = div(c.con - 10, 2)
      assert c2.max_hp == c.max_hp + 6 + con_mod
      # RAW 5e: subir de nivel NO cura. El hp_gain va solo al máximo; el hp
      # actual no cambia (sin ASI de CON → con_retro = 0).
      assert c2.hp == c.hp
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

      # sleep no está en los hechizos iniciales del mago → se añade sin colisión
      refute Enum.any?(c.spells, &(&1.name == "sleep"))

      {:ok, c2} = Heroes.apply_level_up(c, %{spells_added: ["sleep"]})
      assert Enum.any?(c2.spells, &(&1.name == "sleep"))
    end

    test "no duplica un hechizo que el personaje ya conoce (dedup)" do
      {:ok, c} =
        Heroes.build(%{
          name: "X",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      # shield sí lo conoce el mago al crearse → re-añadirlo no duplica
      known = Enum.find(c.spells, &(&1.name == "shield"))
      assert known != nil
      count_before = length(c.spells)

      {:ok, c2} = Heroes.apply_level_up(c, %{spells_added: ["shield"]})
      assert length(c2.spells) == count_before
    end

    test "paladín gana conjuración al subir a L2" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "paladin", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{})
      assert "spellcasting" in c2.class_features
    end

    test "fighter L1→L5 (ASI L4 +2 primario) incluye extra_attack; L3 no" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "fighter", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{})
      {:ok, c3} = Heroes.apply_level_up(c2, %{})
      refute "extra_attack" in c3.class_features

      {:ok, c4} = Heroes.apply_level_up(c3, %{asi: %{str: 2}})
      {:ok, c5} = Heroes.apply_level_up(c4, %{})
      assert c5.level == 5
      assert "extra_attack" in c5.class_features
    end

    test "H1: paladín fija casting_ability al ganar hechizos a L2 (no nil)" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "paladin", background: "soldier"})

      {:ok, c2} = Heroes.apply_level_up(c, %{spells_added: ["bless"]})

      bless = Enum.find(c2.spells, &(&1.name == "bless"))
      assert bless != nil
      assert bless.casting_ability == :cha
    end

    test "H1b: ranger fija casting_ability (:wis) al ganar hechizos a L2" do
      {:ok, c} =
        Heroes.build(%{name: "X", race: "human", class: "ranger", background: "outlander"})

      {:ok, c2} = Heroes.apply_level_up(c, %{spells_added: ["bless"]})

      bless = Enum.find(c2.spells, &(&1.name == "bless"))
      assert bless != nil
      assert bless.casting_ability == :wis
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

  describe "cobertura de gaps" do
    test "MEDIA-3: ASI negativo no permite saltarse el cupo (str+3, con-1)" do
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
          ac: 16
        )

      # Sin el fix, el negativo "compensaría": 3 + (-1) = 2 (dentro del cupo) y
      # aplicaría str+3 (excediendo el máximo de 2 puntos). Con el fix, los
      # negativos se filtran → 3 > 2 → se rechaza.
      assert {:error, msg} = Heroes.apply_level_up(c, %{asi: %{str: 3, con: -1}})
      assert msg =~ "ASI"
    end

    test "MEDIA-4: mago L1→2 rechaza hechizos por encima de max_spell_level" do
      {:ok, c} =
        Heroes.build(%{
          name: "X",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      # max_spell_level(wizard, 2) = 1. acid arrow (L2) y gate (L9) se descartan.
      {:ok, c2} =
        Heroes.apply_level_up(c, %{spells_added: ["acid arrow", "gate", "magic missile"]})

      names = Enum.map(c2.spells, & &1.name)
      assert "magic missile" in names
      refute "acid arrow" in names
      refute "gate" in names
    end

    test "LOW-5: un personaje dañado conserva su daño (no cura al subir)" do
      # Fighter L1, max 12, dañado a 7 hp
      c =
        Character.new(
          name: "X",
          class: "fighter",
          level: 1,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 7,
          max_hp: 12,
          ac: 16
        )

      {:ok, c2} = Heroes.apply_level_up(c, %{})
      # max sube (d10 medio 6 + con_mod +2 = 8 → 20), pero hp NO cambia (RAW)
      assert c2.max_hp == 20
      assert c2.hp == 7
    end

    test "LOW-5: un personaje caído (0 hp) sigue caído tras subir" do
      c =
        Character.new(
          name: "X",
          class: "fighter",
          level: 1,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 0,
          max_hp: 12,
          ac: 16
        )

      {:ok, c2} = Heroes.apply_level_up(c, %{})
      assert c2.max_hp == 20
      # Sigue caído: subir de nivel no revive
      assert c2.hp == 0
    end

    test "LOW-5: la vitalidad retroactiva de CON sí sube el hp actual" do
      # Fighter L3 dañado a 10 hp; ASI de CON (14→16, mod +2→+3)
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
          hp: 10,
          max_hp: 28,
          ac: 16
        )

      {:ok, c4} = Heroes.apply_level_up(c, %{asi: %{con: 2}})
      # con_retro = (3 - 2) * 3 = 3 → el hp actual sube 3 por vitalidad (PHB),
      # pero NO recibe el hp_gain del nuevo nivel (RAW: no cura).
      assert c4.hp == 13
    end

    test "AC: ASI de WIS sube la CA de un monje (Defensa sin Armadura)" do
      # Monk sin armadura: AC = 10 + dex_mod + wis_mod. Subir WIS sube la AC.
      monk =
        Character.new(
          name: "X",
          race: "human",
          class: "monk",
          level: 3,
          str: 10,
          dex: 14,
          con: 12,
          int: 10,
          wis: 14,
          cha: 10,
          hp: 22,
          max_hp: 22,
          ac: 14
        )

      {:ok, m4} = Heroes.apply_level_up(monk, %{asi: %{wis: 2}})
      # dex +2, wis +2 → AC 10 + 2 + 3 = 15
      assert m4.wis == 16
      assert m4.ac == 15
    end

    test "ASI cap 20: no pasa de 20 una característica alta" do
      c =
        Character.new(
          name: "X",
          class: "fighter",
          level: 3,
          str: 19,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          hp: 28,
          max_hp: 28,
          ac: 16
        )

      {:ok, c4} = Heroes.apply_level_up(c, %{asi: %{str: 2}})
      assert c4.str == 20
    end
  end
end
