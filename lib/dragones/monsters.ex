defmodule Dragones.Monsters do
  @moduledoc """
  Prebuilt foes for the DM to spawn. Canonical 5e SRD stats, `side: "enemy"` so
  the WorldDriven policy folds them onto the DM's turn (the DM acts for its
  monsters when their slot in the initiative order comes up).
  """

  alias Dragones.{Character, Item, Weapon}

  @spec goblin(keyword()) :: Character.t()
  def goblin(opts \\ []) do
    %Character{
      name: Keyword.get(opts, :name, "goblin"),
      race: "goblinoid",
      class: "monster",
      side: "enemy",
      level: 1,
      str: 8,
      dex: 14,
      con: 10,
      int: 10,
      wis: 8,
      cha: 8,
      hp: 7,
      max_hp: 7,
      temp_hp: 0,
      ac: 15,
      speed: 30,
      backstory: Keyword.get(opts, :backstory, "A wiry raider with a foul temper."),
      weapons: [scimitar(), shortbow()],
      spells: [],
      inventory: [
        %Item{name: "leather armor", qty: 1, kind: :armor},
        %Item{name: "shield", qty: 1, kind: :armor}
      ],
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: ["dex"]
    }
  end

  defp scimitar,
    do: %Weapon{
      name: "scimitar",
      dice: "1d6",
      damage_type: "slashing",
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
end
