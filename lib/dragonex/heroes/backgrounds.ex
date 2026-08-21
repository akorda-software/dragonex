defmodule Dragonex.Heroes.Backgrounds do
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
          feature: String.t(),
          extra_languages: non_neg_integer()
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
        equipment: [
          %{gear: "holy symbol"},
          %{gear: "prayer book"},
          %{ammo: "sticks of incense", qty: 5},
          %{gear: "vestments"},
          %{gear: "clothes, common"}
        ],
        feature: "shelter_of_the_faithful",
        extra_languages: 2
      },
      %{
        key: "criminal",
        name: "Criminal",
        skills: ["deception", "stealth"],
        equipment: [
          %{gear: "crowbar"},
          %{gear: "dark, common clothes with hood"},
          %{ammo: "daggers", qty: 2}
        ],
        feature: "criminal_contact",
        extra_languages: 0
      },
      %{
        key: "folk hero",
        name: "Folk Hero",
        skills: ["animal_handling", "survival"],
        equipment: [
          %{gear: "artisan's tools"},
          %{gear: "shovel"},
          %{gear: "iron pot"},
          %{gear: "clothes, common"}
        ],
        feature: "rustic_hospitality",
        extra_languages: 0
      },
      %{
        key: "noble",
        name: "Noble",
        skills: ["history", "persuasion"],
        equipment: [
          %{gear: "fine clothes"},
          %{gear: "signet ring"},
          %{ammo: "scroll of pedigree", qty: 1}
        ],
        feature: "position_of_privilege",
        extra_languages: 0
      },
      %{
        key: "sage",
        name: "Sage",
        skills: ["arcana", "history"],
        equipment: [
          %{gear: "bottle of black ink"},
          %{gear: "quill"},
          %{ammo: "letters", qty: 1},
          %{gear: "clothes, common"}
        ],
        feature: "researcher",
        extra_languages: 0
      },
      %{
        key: "soldier",
        name: "Soldier",
        skills: ["athletics", "intimidation"],
        equipment: [
          %{gear: "rank insignia"},
          %{gear: "trophy"},
          %{ammo: "daggers", qty: 1},
          %{gear: "clothes, common"}
        ],
        feature: "military_rank",
        extra_languages: 0
      },
      %{
        key: "charlatan",
        name: "Charlatan",
        skills: ["deception", "sleight_of_hand"],
        equipment: [%{gear: "fine clothes"}, %{gear: "disguise kit"}, %{gear: "tools of the con"}],
        feature: "false_identity",
        extra_languages: 0
      },
      %{
        key: "entertainer",
        name: "Entertainer",
        skills: ["acrobatics", "performance"],
        equipment: [
          %{focus: "musical instrument"},
          %{gear: "fine clothes"},
          %{gear: "favor of an admirer"}
        ],
        feature: "by_popular_demand",
        extra_languages: 0
      },
      %{
        key: "hermit",
        name: "Hermit",
        skills: ["medicine", "religion"],
        equipment: [
          %{gear: "scroll case"},
          %{gear: "winter blanket"},
          %{gear: "herbalism kit"},
          %{gear: "clothes, common"}
        ],
        feature: "discovery",
        extra_languages: 0
      },
      %{
        key: "outlander",
        name: "Outlander",
        skills: ["athletics", "survival"],
        equipment: [
          %{gear: "staff"},
          %{gear: "hunting trap"},
          %{gear: "trophy"},
          %{gear: "clothes, traveler's"}
        ],
        feature: "wanderer",
        extra_languages: 0
      }
    ]
  end
end
