defmodule Dragonex.Archetypes do
  @moduledoc """
  Three prebuilt, fully-configured characters covering the classic D&D triangle:

    * `fighter/1` — STR melee, high HP/AC, simple attack rolls.
    * `wizard/1`  — INT caster, spell save DC + spell attack, low HP.
    * `rogue/1`   — DEX attacker, finesse weapons + ranged.

  They exist to exercise the Rules layer end-to-end without a character editor.
  Every value (abilities, HP, AC, gear) is canonical 5e level-1.

  Options: `name:` and `backstory:` to personalize; everything else is fixed.
  """

  alias Dragonex.{Character, Item, Spell, Weapon}

  @type opts :: [{:name, String.t()} | {:backstory, String.t()}]

  @spec fighter(opts()) :: Character.t()
  def fighter(opts \\ []) do
    %Character{
      name: Keyword.get(opts, :name, "Thane"),
      race: "human",
      class: "fighter",
      level: 1,
      str: 16,
      dex: 12,
      con: 14,
      int: 10,
      wis: 10,
      cha: 10,
      hp: 12,
      max_hp: 12,
      temp_hp: 0,
      concentrating: nil,
      raging: false,
      reckless: false,
      second_wind_used: false,
      damage_resistances: [],
      damage_vulnerabilities: [],
      damage_immunities: [],
      ac: 16,
      speed: 30,
      backstory:
        Keyword.get(
          opts,
          :backstory,
          "A retired soldier who took up the sword again after his village burned."
        ),
      weapons: [longsword(), javelin()],
      spells: [],
      inventory: [
        %Item{name: "chain shirt", qty: 1, kind: :armor},
        %Item{name: "explorer's pack", qty: 1, kind: :gear},
        %Item{name: "torch", qty: 4, kind: :gear}
      ],
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: ["str", "con"]
    }
  end

  @spec wizard(opts()) :: Character.t()
  def wizard(opts \\ []) do
    %Character{
      name: Keyword.get(opts, :name, "Lyra"),
      race: "elf",
      class: "wizard",
      level: 1,
      str: 8,
      dex: 14,
      con: 13,
      int: 16,
      wis: 12,
      cha: 10,
      hp: 7,
      max_hp: 7,
      temp_hp: 0,
      concentrating: nil,
      raging: false,
      reckless: false,
      second_wind_used: false,
      damage_resistances: [],
      damage_vulnerabilities: [],
      damage_immunities: [],
      ac: 12,
      speed: 30,
      backstory:
        Keyword.get(
          opts,
          :backstory,
          "An apprentice who fled her tower with a half-finished spellbook."
        ),
      weapons: [quarterstaff()],
      spells: [firebolt(), magic_missile(), shield()],
      inventory: [
        %Item{name: "spellbook", qty: 1, kind: :gear},
        %Item{name: "component pouch", qty: 1, kind: :gear}
      ],
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: ["int", "wis"]
    }
  end

  @spec rogue(opts()) :: Character.t()
  def rogue(opts \\ []) do
    %Character{
      name: Keyword.get(opts, :name, "Vex"),
      race: "halfling",
      class: "rogue",
      level: 1,
      str: 10,
      dex: 16,
      con: 14,
      int: 12,
      wis: 12,
      cha: 10,
      hp: 10,
      max_hp: 10,
      temp_hp: 0,
      concentrating: nil,
      raging: false,
      reckless: false,
      second_wind_used: false,
      damage_resistances: [],
      damage_vulnerabilities: [],
      damage_immunities: [],
      ac: 14,
      speed: 30,
      backstory:
        Keyword.get(
          opts,
          :backstory,
          "A street thief who stumbled into something far bigger than a purse."
        ),
      weapons: [shortsword(), shortbow()],
      spells: [],
      inventory: [
        %Item{name: "leather armor", qty: 1, kind: :armor},
        %Item{name: "thieves' tools", qty: 1, kind: :gear},
        %Item{name: "dagger", qty: 2, kind: :weapon}
      ],
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: ["dex", "int"]
    }
  end

  defp longsword,
    do: %Weapon{
      name: "longsword",
      dice: "1d8",
      damage_type: "slashing",
      attack_ability: :str
    }

  defp javelin,
    do: %Weapon{
      name: "javelin",
      dice: "1d6",
      damage_type: "piercing",
      attack_ability: :str
    }

  defp quarterstaff,
    do: %Weapon{
      name: "quarterstaff",
      dice: "1d6",
      damage_type: "bludgeoning",
      attack_ability: :str
    }

  defp shortsword,
    do: %Weapon{
      name: "shortsword",
      dice: "1d6",
      damage_type: "piercing",
      attack_ability: :str,
      finesse: true
    }

  defp shortbow,
    do: %Weapon{
      name: "shortbow",
      dice: "1d6",
      damage_type: "piercing",
      attack_ability: :dex,
      ranged: true
    }

  defp firebolt,
    do: %Spell{
      name: "firebolt",
      level: 0,
      kind: :attack,
      casting_ability: :int,
      dice: "1d10",
      damage_type: "fire",
      effect: "A streak of flame streaks to a creature or object."
    }

  defp magic_missile,
    do: %Spell{
      name: "magic missile",
      level: 1,
      kind: :automatic,
      casting_ability: :int,
      dice: "3d4+3",
      damage_type: "force",
      effect: "Three darts of force; each deals 1d4+1 and always hits."
    }

  defp shield,
    do: %Spell{
      name: "shield",
      level: 1,
      kind: :automatic,
      casting_ability: :int,
      effect: "Reaction; +5 AC until the start of your next turn."
    }
end
