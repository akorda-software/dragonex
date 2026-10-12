defmodule Dragonex.Heroes.Races do
  @moduledoc """
  SRD 5.1 razas (nivel 1).

  Cada raza declara bonificadores de característica, velocidad, tamaño, rasgos
  raciales (`traits`, claves estables que `Translations` localiza), idiomas
  (`languages`) y subrazas opcionales. El Half-Elf es un caso especial
  (dos +1 flotantes); el builder los aplica vía `choose_bonus`.

  Los bonificadores se aplican **después** de elegir las puntuaciones base
  (standard array / point buy), así que el rango pre-racial es 8–15 y el
  resultado final debe quedar en 1–20.

  Idiomas: `languages` son los fijos (Común + racial). `extra_languages` es
  el nº de idiomas adicionales a elegir (human +1, half-elf +1, alto elfo +1
  vía subraza). El builder los ofrece en el creador.
  """

  use Gettext, backend: Dragonex.Gettext

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @type subrace :: %{
          key: String.t(),
          name: String.t(),
          bonuses: %{ability() => integer()},
          traits: [String.t()],
          hp_bonus: non_neg_integer(),
          speed: non_neg_integer() | nil,
          choose_bonus: pos_integer() | nil,
          extra_languages: non_neg_integer()
        }

  @type race :: %{
          key: String.t(),
          name: String.t(),
          size: :small | :medium,
          speed: non_neg_integer(),
          bonuses: %{ability() => integer()},
          traits: [String.t()],
          hp_bonus: non_neg_integer(),
          languages: [String.t()],
          extra_languages: non_neg_integer(),
          subraces: [subrace()],
          choose_bonus: pos_integer() | nil
        }

  @spec get(String.t(), String.t() | nil) :: {:ok, race()} | {:error, String.t()}
  def get(race_key, subrace_key \\ nil) do
    case find_race(race_key) do
      nil ->
        {:error, dgettext("engine", "raza desconocida: %{race}", race: race_key)}

      race ->
        if race.subraces == [] do
          {:ok, race}
        else
          case find_subrace(race, subrace_key) do
            nil ->
              {:error,
               dgettext("engine", "la raza %{race} requiere una subraza (%{options})",
                 race: race_key,
                 options: inspect(Enum.map(race.subraces, & &1.key))
               )}

            sub ->
              {:ok, merge_subrace(race, sub)}
          end
        end
    end
  end

  @doc "All race keys (for the wizard / validation)."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(all(), & &1.key)

  @doc "Subrace keys for a race, or `[]` if it has none."
  @spec subrace_keys(String.t()) :: [String.t()]
  def subrace_keys(race_key) do
    case find_race(race_key) do
      nil -> []
      race -> Enum.map(race.subraces, & &1.key)
    end
  end

  @doc "All race entries (parent + subraces), the catalogue source of truth."
  @spec all() :: [race()]
  def all do
    [
      %{
        key: "dwarf",
        name: "Dwarf",
        size: :medium,
        speed: 25,
        bonuses: %{con: 2},
        traits: ~w(darkvision dwarven_resilience stonecunning tool_proficiency),
        hp_bonus: 0,
        languages: ~w(common dwarvish),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "mountain",
            name: "Mountain Dwarf",
            bonuses: %{str: 2},
            traits: ~w(dwarven_armor_training),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          },
          %{
            key: "hill",
            name: "Hill Dwarf",
            bonuses: %{wis: 1},
            traits: ~w(dwarven_toughness),
            hp_bonus: 1,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          }
        ]
      },
      %{
        key: "elf",
        name: "Elf",
        size: :medium,
        speed: 30,
        bonuses: %{dex: 2},
        traits: ~w(darkvision fey_ancestry trance),
        hp_bonus: 0,
        languages: ~w(common elvish),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "high elf",
            name: "High Elf",
            bonuses: %{int: 1},
            traits: ~w(elf_weapon_training cantrip extra_language),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 1
          },
          %{
            key: "wood elf",
            name: "Wood Elf",
            bonuses: %{wis: 1},
            traits: ~w(elf_weapon_training mask_of_the_wild fleet_of_foot),
            hp_bonus: 0,
            speed: 35,
            choose_bonus: nil,
            extra_languages: 0
          },
          %{
            key: "dark elf",
            name: "Dark Elf (Drow)",
            bonuses: %{cha: 1},
            traits: ~w(superior_darkvision sunlight_sensitivity drow_magic drow_weapon_training),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          }
        ]
      },
      %{
        key: "halfling",
        name: "Halfling",
        size: :small,
        speed: 25,
        bonuses: %{dex: 2},
        traits: ~w(lucky brave halfling_nimbleness),
        hp_bonus: 0,
        languages: ~w(common halfling),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "lightfoot",
            name: "Lightfoot Halfling",
            bonuses: %{cha: 1},
            traits: ~w(naturally_stealthy),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          },
          %{
            key: "stout",
            name: "Stout Halfling",
            bonuses: %{con: 1},
            traits: ~w(stout_resilience),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          }
        ]
      },
      %{
        key: "human",
        name: "Human",
        size: :medium,
        speed: 30,
        bonuses: %{str: 1, dex: 1, con: 1, int: 1, wis: 1, cha: 1},
        traits: ~w(extra_language),
        hp_bonus: 0,
        languages: ~w(common),
        extra_languages: 1,
        choose_bonus: nil,
        subraces: []
      },
      %{
        key: "dragonborn",
        name: "Dragonborn",
        size: :medium,
        speed: 30,
        bonuses: %{str: 2, cha: 1},
        traits: ~w(draconic_ancestry breath_weapon damage_resistance),
        hp_bonus: 0,
        languages: ~w(common draconic),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: []
      },
      %{
        key: "gnome",
        name: "Gnome",
        size: :small,
        speed: 25,
        bonuses: %{int: 2},
        traits: ~w(darkvision gnome_cunning),
        hp_bonus: 0,
        languages: ~w(common gnomish),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "forest gnome",
            name: "Forest Gnome",
            bonuses: %{dex: 1},
            traits: ~w(natural_illusionist speak_with_small_beasts),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          },
          %{
            key: "rock gnome",
            name: "Rock Gnome",
            bonuses: %{con: 1},
            traits: ~w(artificers_lore tinker),
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil,
            extra_languages: 0
          }
        ]
      },
      %{
        key: "half-elf",
        name: "Half-Elf",
        size: :medium,
        speed: 30,
        bonuses: %{cha: 2},
        traits: ~w(darkvision fey_ancestry skill_versatility extra_language),
        hp_bonus: 0,
        languages: ~w(common elvish),
        extra_languages: 1,
        choose_bonus: 2,
        subraces: []
      },
      %{
        key: "half-orc",
        name: "Half-Orc",
        size: :medium,
        speed: 30,
        bonuses: %{str: 2, con: 1},
        traits: ~w(darkvision menacing relentless_endurance savage_attacks),
        hp_bonus: 0,
        languages: ~w(common orc),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: []
      },
      %{
        key: "tiefling",
        name: "Tiefling",
        size: :medium,
        speed: 30,
        bonuses: %{int: 1, cha: 2},
        traits: ~w(darkvision hellish_resistance infernal_legacy),
        hp_bonus: 0,
        languages: ~w(common infernal),
        extra_languages: 0,
        choose_bonus: nil,
        subraces: []
      }
    ]
  end

  defp find_race(key), do: Enum.find(all(), &(&1.key == key))

  defp find_subrace(_race, nil), do: nil

  defp find_subrace(race, sub_key) do
    lower = String.downcase(sub_key)

    Enum.find(race.subraces, fn sub ->
      String.downcase(sub.key) == lower or
        String.downcase(sub.name) == lower
    end)
  end

  defp merge_subrace(race, sub) do
    merged_bonuses = Map.merge(race.bonuses, sub.bonuses, fn _k, a, b -> a + b end)

    %{
      key: race.key,
      name: sub.name,
      size: race.size,
      speed: sub.speed || race.speed,
      bonuses: merged_bonuses,
      traits: race.traits ++ sub.traits,
      hp_bonus: race.hp_bonus + sub.hp_bonus,
      languages: race.languages,
      extra_languages: (race.extra_languages || 0) + (sub.extra_languages || 0),
      choose_bonus: race.choose_bonus,
      subraces: []
    }
  end
end
