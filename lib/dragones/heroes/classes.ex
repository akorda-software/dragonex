defmodule Dragones.Heroes.Classes do
  @moduledoc """
  SRD 5.1 classes (level 1).

  Each class declares:
    * `hit_die`         — d6 / d8 / d10 / d12 (the hit die).
    * `primary`         — primary ability (for auto-assigning scores).
    * `saves`           — saving-throw proficiencies (→ `saving_proficiencies`).
    * `skill_count`     — how many skills the class lets you pick.
    * `skill_list`      — the pick list.
    * `equipment`       — the **default** starting equipment (first option of
                          each SRD choice group), as slot maps the builder turns
                          into weapons, inventory and AC.
    * `features`        — level-1 class features.
    * `spellcasting`    — `nil` for non-casters, or a map with casting ability,
                          cantrip/spell counts, and default spell name lists.
    * `priority`        — ability priority order for auto-assigning standard array.
    * `unarmored_defense` — abilities used when unarmoured (Barbarian, Monk).

  See `Dragones.Heroes.Equipment` for the weapon/armor catalogue.
  See `Dragones.Heroes.Spells` for the spell data behind the default picks.
  """

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @type spellcasting :: %{
          ability: ability(),
          cantrips: non_neg_integer(),
          spells_level1: non_neg_integer(),
          prepared: boolean(),
          defaults: %{cantrips: [String.t()], spells: [String.t()]}
        }

  @type class :: %{
          key: String.t(),
          name: String.t(),
          hit_die: pos_integer(),
          primary: ability(),
          saves: [ability()],
          skill_count: pos_integer(),
          skill_list: [String.t()],
          equipment: [map()],
          features: [String.t()],
          spellcasting: spellcasting() | nil,
          priority: [ability()],
          unarmored_defense: [ability()] | nil
        }

  @spec get(String.t()) :: {:ok, class()} | {:error, String.t()}
  def get(key) when is_binary(key) do
    case Enum.find(all(), &(&1.key == key)) do
      nil -> {:error, "unknown class: #{key}"}
      c -> {:ok, c}
    end
  end

  @doc "True when the class key has a spellcasting progression (a caster class)."
  @spec caster?(String.t() | nil) :: boolean()
  def caster?(nil), do: false

  def caster?(key) do
    case get(key) do
      {:ok, %{spellcasting: nil}} -> false
      {:ok, %{spellcasting: _}} -> true
      _ -> false
    end
  end

  @doc "The default spell names (cantrips + level-1) a class starts with, or []."
  @spec default_spell_names(String.t() | nil) :: [String.t()]
  def default_spell_names(class_key) do
    case get(class_key || "") do
      {:ok, %{spellcasting: %{defaults: %{cantrips: c, spells: s}}}} -> c ++ s
      _ -> []
    end
  end

  @doc "All class keys."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(all(), & &1.key)

  @spec all() :: [class()]
  defp all do
    [
      %{
        key: "barbarian",
        name: "Barbarian",
        hit_die: 12,
        primary: :str,
        saves: [:str, :con],
        skill_count: 2,
        skill_list: ~w(animal_handling athletics intimidation nature perception survival),
        equipment: [
          %{weapon: "greataxe"},
          %{weapon: "handaxe"},
          %{ammo: "javelins", qty: 4},
          %{gear: "explorer's pack"}
        ],
        features: ~w(rage unarmored_defense),
        spellcasting: nil,
        priority: [:str, :con, :dex, :wis, :cha, :int],
        unarmored_defense: [:dex, :con]
      },
      %{
        key: "bard",
        name: "Bard",
        hit_die: 8,
        primary: :cha,
        saves: [:dex, :cha],
        skill_count: 3,
        skill_list: :any,
        equipment: [
          %{weapon: "rapier"},
          %{armor: "leather armor"},
          %{weapon: "dagger"},
          %{gear: "diplomat's pack"},
          %{focus: "lute"}
        ],
        features: ~w(bardic_inspiration spellcasting),
        spellcasting: %{
          ability: :cha,
          cantrips: 2,
          spells_level1: 4,
          prepared: false,
          defaults: %{
            cantrips: ["vicious mockery", "prestidigitation"],
            spells: ["charm person", "healing word", "bane", "heroism"]
          }
        },
        priority: [:cha, :dex, :con, :wis, :int, :str],
        unarmored_defense: nil
      },
      %{
        key: "cleric",
        name: "Cleric",
        hit_die: 8,
        primary: :wis,
        saves: [:wis, :cha],
        skill_count: 2,
        skill_list: ~w(history insight medicine persuasion religion),
        equipment: [
          %{weapon: "mace"},
          %{armor: "scale mail"},
          %{shield: true},
          %{weapon: "light crossbow"},
          %{ammo: "bolts", qty: 20},
          %{gear: "priest's pack"},
          %{focus: "holy symbol"}
        ],
        features: ~w(spellcasting divine_domain),
        spellcasting: %{
          ability: :wis,
          cantrips: 3,
          spells_level1: 0,
          prepared: true,
          defaults: %{
            cantrips: ["guidance", "sacred flame", "thaumaturgy"],
            spells: ["bless", "cure wounds", "guiding bolt", "healing word", "shield of faith"]
          }
        },
        priority: [:wis, :con, :str, :dex, :cha, :int],
        unarmored_defense: nil
      },
      %{
        key: "druid",
        name: "Druid",
        hit_die: 8,
        primary: :wis,
        saves: [:int, :wis],
        skill_count: 2,
        skill_list: ~w(arcana animal_handling insight medicine nature perception religion survival),
        equipment: [
          %{weapon: "scimitar"},
          %{armor: "leather armor"},
          %{shield: true},
          %{gear: "explorer's pack"},
          %{focus: "druidic focus"}
        ],
        features: ~w(druidic spellcasting wild_shape),
        spellcasting: %{
          ability: :wis,
          cantrips: 2,
          spells_level1: 0,
          prepared: true,
          defaults: %{
            cantrips: ["druidcraft", "produce flame"],
            spells: ["cure wounds", "entangle", "thunderwave", "faerie fire"]
          }
        },
        priority: [:wis, :con, :dex, :str, :int, :cha],
        unarmored_defense: nil
      },
      %{
        key: "fighter",
        name: "Fighter",
        hit_die: 10,
        primary: :str,
        saves: [:str, :con],
        skill_count: 2,
        skill_list: ~w(acrobatics animal_handling athletics history insight intimidation perception survival),
        equipment: [
          %{armor: "chain mail"},
          %{shield: true},
          %{weapon: "longsword"},
          %{weapon: "light crossbow"},
          %{ammo: "bolts", qty: 20},
          %{gear: "dungeoneer's pack"}
        ],
        features: ~w(fighting_style second_wind),
        spellcasting: nil,
        priority: [:str, :con, :dex, :wis, :cha, :int],
        unarmored_defense: nil
      },
      %{
        key: "monk",
        name: "Monk",
        hit_die: 8,
        primary: :dex,
        saves: [:str, :dex],
        skill_count: 2,
        skill_list: ~w(acrobatics athletics history insight religion stealth),
        equipment: [
          %{weapon: "shortsword"},
          %{ammo: "darts", qty: 10},
          %{gear: "dungeoneer's pack"}
        ],
        features: ~w(unarmored_defense martial_arts),
        spellcasting: nil,
        priority: [:dex, :wis, :con, :str, :int, :cha],
        unarmored_defense: [:dex, :wis]
      },
      %{
        key: "paladin",
        name: "Paladin",
        hit_die: 10,
        primary: :str,
        saves: [:wis, :cha],
        skill_count: 2,
        skill_list: ~w(athletics insight intimidation medicine persuasion religion),
        equipment: [
          %{armor: "chain mail"},
          %{shield: true},
          %{weapon: "longsword"},
          %{ammo: "javelins", qty: 5},
          %{gear: "priest's pack"}
        ],
        features: ~w(divine_sense lay_on_hands),
        spellcasting: nil,
        priority: [:str, :cha, :con, :wis, :dex, :int],
        unarmored_defense: nil
      },
      %{
        key: "ranger",
        name: "Ranger",
        hit_die: 10,
        primary: :dex,
        saves: [:str, :dex],
        skill_count: 3,
        skill_list: ~w(animal_handling athletics insight investigation nature perception stealth survival),
        equipment: [
          %{armor: "scale mail"},
          %{weapon: "shortsword"},
          %{weapon: "longbow"},
          %{ammo: "arrows", qty: 20},
          %{gear: "dungeoneer's pack"}
        ],
        features: ~w(favored_enemy natural_explorer),
        spellcasting: nil,
        priority: [:dex, :wis, :con, :str, :int, :cha],
        unarmored_defense: nil
      },
      %{
        key: "rogue",
        name: "Rogue",
        hit_die: 8,
        primary: :dex,
        saves: [:dex, :int],
        skill_count: 4,
        skill_list: ~w(acrobatics athletics deception insight intimidation investigation perception performance persuasion sleight_of_hand stealth),
        equipment: [
          %{weapon: "rapier"},
          %{weapon: "shortbow"},
          %{ammo: "arrows", qty: 20},
          %{armor: "leather armor"},
          %{weapon: "dagger"},
          %{ammo: "daggers", qty: 2},
          %{gear: "burglar's pack"},
          %{gear: "thieves' tools"}
        ],
        features: ~w(expertise sneak_attack thieves_cant),
        spellcasting: nil,
        priority: [:dex, :con, :int, :wis, :cha, :str],
        unarmored_defense: nil
      },
      %{
        key: "sorcerer",
        name: "Sorcerer",
        hit_die: 6,
        primary: :cha,
        saves: [:con, :cha],
        skill_count: 2,
        skill_list: ~w(arcana deception insight intimidation persuasion religion),
        equipment: [
          %{weapon: "quarterstaff"},
          %{weapon: "dagger"},
          %{ammo: "daggers", qty: 2},
          %{gear: "component pouch"},
          %{gear: "explorer's pack"}
        ],
        features: ~w(spellcasting sorcerous_origin font_of_magic),
        spellcasting: %{
          ability: :cha,
          cantrips: 4,
          spells_level1: 2,
          prepared: false,
          defaults: %{
            cantrips: ["fire bolt", "acid splash", "light", "mage hand"],
            spells: ["burning hands", "shield"]
          }
        },
        priority: [:cha, :con, :dex, :int, :wis, :str],
        unarmored_defense: nil
      },
      %{
        key: "warlock",
        name: "Warlock",
        hit_die: 8,
        primary: :cha,
        saves: [:wis, :cha],
        skill_count: 2,
        skill_list: ~w(arcana deception history intimidation investigation nature religion),
        equipment: [
          %{weapon: "light crossbow"},
          %{ammo: "bolts", qty: 20},
          %{weapon: "dagger"},
          %{ammo: "daggers", qty: 2},
          %{armor: "leather armor"},
          %{gear: "scholar's pack"},
          %{gear: "component pouch"}
        ],
        features: ~w(eldritch_invocations pact_magic otherworldly_patron),
        spellcasting: %{
          ability: :cha,
          cantrips: 2,
          spells_level1: 2,
          prepared: false,
          defaults: %{
            cantrips: ["eldritch blast", "mage hand"],
            spells: ["hex", "charm person"]
          }
        },
        priority: [:cha, :con, :dex, :int, :wis, :str],
        unarmored_defense: nil
      },
      %{
        key: "wizard",
        name: "Wizard",
        hit_die: 6,
        primary: :int,
        saves: [:int, :wis],
        skill_count: 2,
        skill_list: ~w(arcana history insight investigation medicine religion),
        equipment: [
          %{weapon: "quarterstaff"},
          %{gear: "component pouch"},
          %{gear: "scholar's pack"},
          %{focus: "spellbook"}
        ],
        features: ~w(spellcasting arcane_recovery ritual_casting),
        spellcasting: %{
          ability: :int,
          cantrips: 3,
          spells_level1: 6,
          prepared: false,
          defaults: %{
            cantrips: ["fire bolt", "light", "mage hand"],
            spells: ["burning hands", "charm person", "detect magic", "magic missile", "shield", "thunderwave"]
          }
        },
        priority: [:int, :con, :dex, :wis, :cha, :str],
        unarmored_defense: nil
      }
    ]
  end
end
