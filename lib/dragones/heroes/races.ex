defmodule Dragones.Heroes.Races do
  @moduledoc """
  SRD 5.1 races (level 1).

  Each race declares ability bonuses, speed, size, racial traits, and optional
  subraces. Half-Elf is a special case (two floating +1 bonuses); the builder
  applies them via `choose_bonus` defaults.

  Ability bonuses are applied **after** the base scores are chosen (standard
  array / point buy), so the pre-racial range is 8–15 and the final result must
  stay within 1–20.
  """

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @type subrace :: %{
          key: String.t(),
          name: String.t(),
          bonuses: %{ability() => integer()},
          traits: [String.t()],
          hp_bonus: non_neg_integer(),
          speed: non_neg_integer() | nil,
          choose_bonus: pos_integer() | nil
        }

  @type race :: %{
          key: String.t(),
          name: String.t(),
          size: :small | :medium,
          speed: non_neg_integer(),
          bonuses: %{ability() => integer()},
          traits: [String.t()],
          hp_bonus: non_neg_integer(),
          subraces: [subrace()],
          choose_bonus: pos_integer() | nil
        }

  @spec get(String.t(), String.t() | nil) :: {:ok, race()} | {:error, String.t()}
  def get(race_key, subrace_key \\ nil) do
    case find_race(race_key) do
      nil ->
        {:error, "unknown race: #{race_key}"}

      race ->
        if race.subraces == [] do
          {:ok, race}
        else
          case find_subrace(race, subrace_key) do
            nil ->
              {:error,
               "race #{race_key} requires a subrace (#{inspect(Enum.map(race.subraces, & &1.key))})"}

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

  @spec all() :: [race()]
  defp all do
    [
      %{
        key: "dwarf",
        name: "Dwarf",
        size: :medium,
        speed: 25,
        bonuses: %{con: 2},
        traits: ["darkvision", "dwarven resilience", "stonecunning", "tool proficiency"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "mountain",
            name: "Mountain Dwarf",
            bonuses: %{str: 2},
            traits: ["dwarven armor training"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          },
          %{
            key: "hill",
            name: "Hill Dwarf",
            bonuses: %{wis: 1},
            traits: ["dwarven toughness"],
            hp_bonus: 1,
            speed: nil,
            choose_bonus: nil
          }
        ]
      },
      %{
        key: "elf",
        name: "Elf",
        size: :medium,
        speed: 30,
        bonuses: %{dex: 2},
        traits: ["darkvision", "fey ancestry", "trance"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "high elf",
            name: "High Elf",
            bonuses: %{int: 1},
            traits: ["elf weapon training", "cantrip", "extra language"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          },
          %{
            key: "wood elf",
            name: "Wood Elf",
            bonuses: %{wis: 1},
            traits: ["elf weapon training", "mask of the wild", "fleet of foot"],
            hp_bonus: 0,
            speed: 35,
            choose_bonus: nil
          },
          %{
            key: "dark elf",
            name: "Dark Elf (Drow)",
            bonuses: %{cha: 1},
            traits: ["superior darkvision", "sunlight sensitivity", "drow magic", "drow weapon training"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          }
        ]
      },
      %{
        key: "halfling",
        name: "Halfling",
        size: :small,
        speed: 25,
        bonuses: %{dex: 2},
        traits: ["lucky", "brave", "halfling nimbleness"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "lightfoot",
            name: "Lightfoot Halfling",
            bonuses: %{cha: 1},
            traits: ["naturally stealthy"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          },
          %{
            key: "stout",
            name: "Stout Halfling",
            bonuses: %{con: 1},
            traits: ["stout resilience"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          }
        ]
      },
      %{
        key: "human",
        name: "Human",
        size: :medium,
        speed: 30,
        bonuses: %{str: 1, dex: 1, con: 1, int: 1, wis: 1, cha: 1},
        traits: ["extra language"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: []
      },
      %{
        key: "dragonborn",
        name: "Dragonborn",
        size: :medium,
        speed: 30,
        bonuses: %{str: 2, cha: 1},
        traits: ["draconic ancestry", "breath weapon", "damage resistance"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: []
      },
      %{
        key: "gnome",
        name: "Gnome",
        size: :small,
        speed: 25,
        bonuses: %{int: 2},
        traits: ["darkvision", "gnome cunning"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: [
          %{
            key: "forest gnome",
            name: "Forest Gnome",
            bonuses: %{dex: 1},
            traits: ["natural illusionist", "speak with small beasts"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          },
          %{
            key: "rock gnome",
            name: "Rock Gnome",
            bonuses: %{con: 1},
            traits: ["artificer's lore", "tinker"],
            hp_bonus: 0,
            speed: nil,
            choose_bonus: nil
          }
        ]
      },
      %{
        key: "half-elf",
        name: "Half-Elf",
        size: :medium,
        speed: 30,
        bonuses: %{cha: 2},
        traits: ["darkvision", "fey ancestry", "skill versatility"],
        hp_bonus: 0,
        choose_bonus: 2,
        subraces: []
      },
      %{
        key: "half-orc",
        name: "Half-Orc",
        size: :medium,
        speed: 30,
        bonuses: %{str: 2, con: 1},
        traits: ["darkvision", "menacing", "relentless endurance", "savage attacks"],
        hp_bonus: 0,
        choose_bonus: nil,
        subraces: []
      },
      %{
        key: "tiefling",
        name: "Tiefling",
        size: :medium,
        speed: 30,
        bonuses: %{int: 1, cha: 2},
        traits: ["darkvision", "hellish resistance", "infernal legacy"],
        hp_bonus: 0,
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
      choose_bonus: race.choose_bonus,
      subraces: []
    }
  end
end
