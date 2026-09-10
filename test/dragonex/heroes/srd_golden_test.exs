defmodule Dragonex.Heroes.SrdGoldenTest do
  @moduledoc """
  Golden SRD 5.1 del creador (F6.5): 12 clases × niveles {1, 3, 5}.

  Oráculos escritos a mano contra SRD 5.1 y el modelo Dragonex documentado.
  No se copia la salida de `Heroes.build` como tabla esperada.

  ## Inputs fijos

  Humano sin subraza (ASI +1 a todas), trasfondo soldier, standard array
  autoasignado por `class.priority` (no point-buy), equipo/skills/spells
  default. L1 via `Heroes.build/1`. L3/L5: bucle `Heroes.apply_level_up/2`
  (L2, L3, …) — no `choices[:level]`. ASI solo en L4: +2 al primario
  (primer ability de `priority`), cap 20. Tras cada subida se pone
  `hp = max_hp` en el helper (simula descanso): LevelUp no cura (D11).

  ## Cálculo (humano + array 15/14/13/12/10/8)

  Scores finales L1 = array + 1 → 16/15/14/13/11/9. CON queda +2 en las
  12 clases. HP L1 = hit_die + 2. Subida = `div(die, 2) + 1 + 2`.
  AC: armadura default + DEX con techo, o unarmored_defense (bárbaro/monje).
  Slots: tabla PHB de full-caster / half-caster L2+; warlock Pact Magic
  (D40). DC = 8 + prof (L1–4 = 2, L5 = 3) +
  mod de conjuro.   Features: las de L1 del catálogo; paladín/ranger
  ganan `spellcasting` a L2 (R09); marciales ganan `extra_attack` a L5 (D35).

  ## Simplificaciones declaradas (no son bugs; no se implementan aquí)

  * Feats (D13) — ASI es +2, nunca dote.
  * `spells_known` / cantrips por nivel (D14) — sin cap estricto.
  * Features por nivel salvo Extra Attack D35 y spellcasting paladín/ranger L2.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Heroes, Spell, SpellSlots}
  alias Dragonex.Rules.{Ability, Combat}

  @classes ~w(
    barbarian bard cleric druid fighter monk
    paladin ranger rogue sorcerer warlock wizard
  )

  # Primer ability de class.priority (primario). ASI L4 = +2 aquí.
  @primary %{
    "barbarian" => :str,
    "bard" => :cha,
    "cleric" => :wis,
    "druid" => :wis,
    "fighter" => :str,
    "monk" => :dex,
    "paladin" => :str,
    "ranger" => :dex,
    "rogue" => :dex,
    "sorcerer" => :cha,
    "warlock" => :cha,
    "wizard" => :int
  }

  # L1 = array por priority + humano +1. No se lee del builder.
  @l1_scores %{
    "barbarian" => %{str: 16, dex: 14, con: 15, int: 9, wis: 13, cha: 11},
    "bard" => %{str: 9, dex: 15, con: 14, int: 11, wis: 13, cha: 16},
    "cleric" => %{str: 14, dex: 13, con: 15, int: 9, wis: 16, cha: 11},
    "druid" => %{str: 13, dex: 14, con: 15, int: 11, wis: 16, cha: 9},
    "fighter" => %{str: 16, dex: 14, con: 15, int: 9, wis: 13, cha: 11},
    "monk" => %{str: 13, dex: 16, con: 14, int: 11, wis: 15, cha: 9},
    "paladin" => %{str: 16, dex: 11, con: 14, int: 9, wis: 13, cha: 15},
    "ranger" => %{str: 13, dex: 16, con: 14, int: 11, wis: 15, cha: 9},
    "rogue" => %{str: 9, dex: 16, con: 15, int: 14, wis: 13, cha: 11},
    "sorcerer" => %{str: 9, dex: 14, con: 15, int: 13, wis: 11, cha: 16},
    "warlock" => %{str: 9, dex: 14, con: 15, int: 13, wis: 11, cha: 16},
    "wizard" => %{str: 9, dex: 14, con: 15, int: 16, wis: 13, cha: 11}
  }

  # HP: d12→14/32/50, d10→12/28/44, d8→10/24/38, d6→8/20/32 (CON +2, media HD).
  # AC L5 sube en monk (DEX ASI, unarmored) y rogue (leather + DEX); ranger
  # scale mail techo DEX 2 no cambia. DC L5 full-casters 15 (primario 18, prof 3);
  # paladín/ranger 13 (CHA/WIS 15, prof 3) y nil a L1 (R09).
  @oracles %{
    "barbarian" => %{
      saves: ["str", "con"],
      features: ~w(rage unarmored_defense),
      casting: nil,
      levels: %{
        1 => %{hp: 14, ac: 14, slots: %{}, dc: nil},
        3 => %{hp: 32, ac: 14, slots: %{}, dc: nil},
        5 => %{hp: 50, ac: 14, slots: %{}, dc: nil}
      }
    },
    "bard" => %{
      saves: ["dex", "cha"],
      features: ~w(bardic_inspiration spellcasting),
      casting: :cha,
      levels: %{
        1 => %{hp: 10, ac: 13, slots: %{1 => 2}, dc: 13},
        3 => %{hp: 24, ac: 13, slots: %{1 => 4, 2 => 2}, dc: 13},
        5 => %{hp: 38, ac: 13, slots: %{1 => 4, 2 => 3, 3 => 2}, dc: 15}
      }
    },
    "cleric" => %{
      saves: ["wis", "cha"],
      features: ~w(spellcasting divine_domain),
      casting: :wis,
      levels: %{
        1 => %{hp: 10, ac: 17, slots: %{1 => 2}, dc: 13},
        3 => %{hp: 24, ac: 17, slots: %{1 => 4, 2 => 2}, dc: 13},
        5 => %{hp: 38, ac: 17, slots: %{1 => 4, 2 => 3, 3 => 2}, dc: 15}
      }
    },
    "druid" => %{
      saves: ["int", "wis"],
      features: ~w(druidic spellcasting wild_shape),
      casting: :wis,
      levels: %{
        1 => %{hp: 10, ac: 15, slots: %{1 => 2}, dc: 13},
        3 => %{hp: 24, ac: 15, slots: %{1 => 4, 2 => 2}, dc: 13},
        5 => %{hp: 38, ac: 15, slots: %{1 => 4, 2 => 3, 3 => 2}, dc: 15}
      }
    },
    "fighter" => %{
      saves: ["str", "con"],
      features: ~w(fighting_style second_wind),
      casting: nil,
      levels: %{
        1 => %{hp: 12, ac: 18, slots: %{}, dc: nil},
        3 => %{hp: 28, ac: 18, slots: %{}, dc: nil},
        5 => %{hp: 44, ac: 18, slots: %{}, dc: nil}
      }
    },
    "monk" => %{
      saves: ["str", "dex"],
      features: ~w(unarmored_defense martial_arts),
      casting: nil,
      levels: %{
        1 => %{hp: 10, ac: 15, slots: %{}, dc: nil},
        3 => %{hp: 24, ac: 15, slots: %{}, dc: nil},
        5 => %{hp: 38, ac: 16, slots: %{}, dc: nil}
      }
    },
    "paladin" => %{
      saves: ["wis", "cha"],
      features: ~w(divine_sense lay_on_hands),
      casting: :cha,
      levels: %{
        1 => %{hp: 12, ac: 18, slots: %{}, dc: nil},
        3 => %{hp: 28, ac: 18, slots: %{1 => 3}, dc: 12},
        5 => %{hp: 44, ac: 18, slots: %{1 => 4, 2 => 2}, dc: 13}
      }
    },
    "ranger" => %{
      saves: ["str", "dex"],
      features: ~w(favored_enemy natural_explorer),
      casting: :wis,
      levels: %{
        1 => %{hp: 12, ac: 16, slots: %{}, dc: nil},
        3 => %{hp: 28, ac: 16, slots: %{1 => 3}, dc: 12},
        5 => %{hp: 44, ac: 16, slots: %{1 => 4, 2 => 2}, dc: 13}
      }
    },
    "rogue" => %{
      saves: ["dex", "int"],
      features: ~w(expertise sneak_attack thieves_cant),
      casting: nil,
      levels: %{
        1 => %{hp: 10, ac: 14, slots: %{}, dc: nil},
        3 => %{hp: 24, ac: 14, slots: %{}, dc: nil},
        5 => %{hp: 38, ac: 15, slots: %{}, dc: nil}
      }
    },
    "sorcerer" => %{
      saves: ["con", "cha"],
      features: ~w(spellcasting sorcerous_origin font_of_magic),
      casting: :cha,
      levels: %{
        1 => %{hp: 8, ac: 12, slots: %{1 => 2}, dc: 13},
        3 => %{hp: 20, ac: 12, slots: %{1 => 4, 2 => 2}, dc: 13},
        5 => %{hp: 32, ac: 12, slots: %{1 => 4, 2 => 3, 3 => 2}, dc: 15}
      }
    },
    "warlock" => %{
      saves: ["wis", "cha"],
      features: ~w(eldritch_invocations pact_magic otherworldly_patron),
      casting: :cha,
      levels: %{
        1 => %{hp: 10, ac: 13, slots: %{1 => 1}, dc: 13},
        3 => %{hp: 24, ac: 13, slots: %{2 => 2}, dc: 13},
        5 => %{hp: 38, ac: 13, slots: %{3 => 2}, dc: 15}
      }
    },
    "wizard" => %{
      saves: ["int", "wis"],
      features: ~w(spellcasting arcane_recovery ritual_casting),
      casting: :int,
      levels: %{
        1 => %{hp: 8, ac: 12, slots: %{1 => 2}, dc: 13},
        3 => %{hp: 20, ac: 12, slots: %{1 => 4, 2 => 2}, dc: 13},
        5 => %{hp: 32, ac: 12, slots: %{1 => 4, 2 => 3, 3 => 2}, dc: 15}
      }
    }
  }

  describe "golden SRD 12 clases × L1/L3/L5" do
    for class <- @classes, level <- [1, 3, 5] do
      test "#{class} L#{level}" do
        class = unquote(class)
        level = unquote(level)
        meta = @oracles[class]
        expected = meta.levels[level]
        c = sheet(class, level)

        assert c.level == level
        assert c.hp == expected.hp
        assert c.max_hp == expected.hp
        assert c.ac == expected.ac
        assert c.saving_proficiencies == meta.saves
        assert SpellSlots.for_class(class, level) == expected.slots

        feats = expected_features(class, level, meta.features)

        for feature <- feats do
          assert feature in c.class_features
        end

        if "extra_attack" in feats do
          assert "extra_attack" in c.class_features
        else
          refute "extra_attack" in c.class_features
        end

        if level == 1 do
          scores = @l1_scores[class]
          assert c.str == scores.str
          assert c.dex == scores.dex
          assert c.con == scores.con
          assert c.int == scores.int
          assert c.wis == scores.wis
          assert c.cha == scores.cha
        end

        if level == 5 do
          assert ability_score(c, @primary[class]) == 18
        end

        if expected.dc do
          probe = %Spell{
            name: "probe",
            level: 1,
            kind: :save,
            casting_ability: meta.casting,
            save_ability: :wis
          }

          assert Combat.spell_save_dc(c, probe) == expected.dc

          assert 8 + Ability.proficiency(level) +
                   Ability.modifier(ability_score(c, meta.casting)) ==
                   expected.dc
        end
      end
    end
  end

  defp sheet(class, 1) do
    {:ok, c} =
      Heroes.build(%{name: "Golden", race: "human", class: class, background: "soldier"})

    c
  end

  defp sheet(class, target) when target in [3, 5] do
    primary = @primary[class]

    Enum.reduce(2..target, sheet(class, 1), fn level, acc ->
      choices = if level == 4, do: %{asi: %{primary => 2}}, else: %{}
      {:ok, next} = Heroes.apply_level_up(acc, choices)
      rest(next)
    end)
  end

  defp rest(c), do: %{c | hp: c.max_hp}

  @extra_attack_classes ~w(fighter barbarian paladin ranger monk)

  defp expected_features(class, level, l1) do
    l1
    |> maybe_spellcasting(class, level)
    |> maybe_extra_attack(class, level)
  end

  defp maybe_spellcasting(features, class, level)
       when class in ["paladin", "ranger"] and level >= 2,
       do: features ++ ["spellcasting"]

  defp maybe_spellcasting(features, _class, _level), do: features

  defp maybe_extra_attack(features, class, level)
       when class in @extra_attack_classes and level >= 5,
       do: features ++ ["extra_attack"]

  defp maybe_extra_attack(features, _class, _level), do: features

  defp ability_score(c, :str), do: c.str
  defp ability_score(c, :dex), do: c.dex
  defp ability_score(c, :con), do: c.con
  defp ability_score(c, :int), do: c.int
  defp ability_score(c, :wis), do: c.wis
  defp ability_score(c, :cha), do: c.cha
end
