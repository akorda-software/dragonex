defmodule Dragones.Heroes.Backgrounds do
  @moduledoc """
  SRD 5.1 backgrounds (a representative subset).

  Each background grants **two skill proficiencies** and a small set of starting
  equipment. The builder merges the background skills with the class skill
  picks and adds the background gear to the inventory.

  The skill proficiencies from a background are **extra** — they don't count
  against the class's skill-pick budget. Per 5e, background skills that overlap
  with class-chosen skills let you pick a replacement, but the builder keeps it
  simple: duplicates are just skipped.
  """

  @type background :: %{
          key: String.t(),
          name: String.t(),
          skills: [String.t()],
          equipment: [map()],
          feature: String.t()
        }

  @spec get(String.t()) :: {:ok, background()} | {:error, String.t()}
  def get(key) when is_binary(key) do
    case Enum.find(all(), &(&1.key == key)) do
      nil -> {:error, "unknown background: #{key}"}
      bg -> {:ok, bg}
    end
  end

  @doc "All background keys."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(all(), & &1.key)

  @spec all() :: [background()]
  defp all do
    [
      %{
        key: "acolyte",
        name: "Acolyte",
        skills: ["insight", "religion"],
        equipment: [%{gear: "holy symbol"}, %{gear: "prayer book"}, %{ammo: "sticks of incense", qty: 5}, %{gear: "vestments"}, %{gear: "clothes, common"}],
        feature: "Shelter of the Faithful"
      },
      %{
        key: "criminal",
        name: "Criminal",
        skills: ["deception", "stealth"],
        equipment: [%{gear: "crowbar"}, %{gear: "dark, common clothes with hood"}, %{ammo: "daggers", qty: 2}],
        feature: "Criminal Contact"
      },
      %{
        key: "folk hero",
        name: "Folk Hero",
        skills: ["animal_handling", "survival"],
        equipment: [%{gear: "artisan's tools"}, %{gear: "shovel"}, %{gear: "iron pot"}, %{gear: "clothes, common"}],
        feature: "Rustic Hospitality"
      },
      %{
        key: "noble",
        name: "Noble",
        skills: ["history", "persuasion"],
        equipment: [%{gear: "fine clothes"}, %{gear: "signet ring"}, %{ammo: "scroll of pedigree", qty: 1}],
        feature: "Position of Privilege"
      },
      %{
        key: "sage",
        name: "Sage",
        skills: ["arcana", "history"],
        equipment: [%{gear: "bottle of black ink"}, %{gear: "quill"}, %{ammo: "letters", qty: 1}, %{gear: "clothes, common"}],
        feature: "Researcher"
      },
      %{
        key: "soldier",
        name: "Soldier",
        skills: ["athletics", "intimidation"],
        equipment: [%{gear: "rank insignia"}, %{gear: "trophy"}, %{ammo: "daggers", qty: 1}, %{gear: "clothes, common"}],
        feature: "Military Rank"
      },
      %{
        key: "charlatan",
        name: "Charlatan",
        skills: ["deception", "sleight_of_hand"],
        equipment: [%{gear: "fine clothes"}, %{gear: "disguise kit"}, %{gear: "tools of the con"}],
        feature: "False Identity"
      },
      %{
        key: "entertainer",
        name: "Entertainer",
        skills: ["acrobatics", "performance"],
        equipment: [%{focus: "musical instrument"}, %{gear: "fine clothes"}, %{gear: "favor of an admirer"}],
        feature: "By Popular Demand"
      },
      %{
        key: "hermit",
        name: "Hermit",
        skills: ["medicine", "religion"],
        equipment: [%{gear: "scroll case"}, %{gear: "winter blanket"}, %{gear: "herbalism kit"}, %{gear: "clothes, common"}],
        feature: "Discovery"
      },
      %{
        key: "outlander",
        name: "Outlander",
        skills: ["athletics", "survival"],
        equipment: [%{gear: "staff"}, %{gear: "hunting trap"}, %{gear: "trophy"}, %{gear: "clothes, traveler's"}],
        feature: "Wanderer"
      }
    ]
  end
end
