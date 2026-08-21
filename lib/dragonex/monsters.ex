defmodule Dragonex.Monsters do
  @moduledoc """
  Prebuilt foes for the DM to spawn. Canonical 5e SRD stats, `side: "enemy"` so
  the WorldDriven policy folds them onto the DM's turn (the DM acts for its
  monsters when their slot in the initiative order comes up).

  Each monster is CR-rated so the DM can gauge encounter difficulty:
    * CR 1/4: goblin, kobold, bandit, skeleton, wolf
    * CR 1/2: orc, hobgoblin
    * CR 1:   ogre
  """

  alias Dragonex.{Character, Item, Weapon}

  @type opts :: [{:name, String.t()} | {:backstory, String.t()}]

  # --------------------------------------------------------------- catalog

  @doc "All available monsters as %{key => builder}."
  @spec catalog() :: %{String.t() => (keyword() -> Character.t())}
  def catalog do
    %{
      "goblin" => &goblin/1,
      "kobold" => &kobold/1,
      "bandit" => &bandit/1,
      "skeleton" => &skeleton/1,
      "wolf" => &wolf/1,
      "orc" => &orc/1,
      "hobgoblin" => &hobgoblin/1,
      "ogre" => &ogre/1,
      # Practice targets — inert dummies/stumps/dummies with HP and a low AC so
      # PCs can roll attacks against them in a training arena without inventing
      # phantoms. They have no weapons, so when their turn comes up the DM just
      # narrates them swaying / doing nothing.
      "training_dummy" => &training_dummy/1,
      "archery_target" => &archery_target/1
    }
  end

  @doc "Look up a monster builder by key."
  @spec get(String.t()) :: (keyword() -> Character.t()) | nil
  def get(key), do: Map.get(catalog(), key)

  @doc "All monster keys."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(catalog()) |> Enum.sort()

  # ----------------------------------------------------------------- CR 1/4

  @spec goblin(opts()) :: Character.t()
  def goblin(opts \\ []) do
    base(opts, "goblinoid", "goblin", "A wiry raider with a foul temper.", 7, 15, 30,
      str: 8,
      dex: 14,
      con: 10,
      int: 10,
      wis: 8,
      cha: 8,
      weapons: [scimitar(), shortbow()],
      inventory: [leather(), shield()],
      saves: ["dex"]
    )
  end

  @spec kobold(opts()) :: Character.t()
  def kobold(opts \\ []) do
    base(
      opts,
      "reptilian",
      "kobold",
      "A small, scaled creature with a flickering tongue.",
      7,
      12,
      30,
      str: 7,
      dex: 15,
      con: 9,
      int: 8,
      wis: 7,
      cha: 8,
      weapons: [dagger(), sling()],
      saves: ["dex"]
    )
  end

  @spec bandit(opts()) :: Character.t()
  def bandit(opts \\ []) do
    base(opts, "human", "bandit", "A desperate highway robber.", 11, 12, 30,
      str: 11,
      dex: 12,
      con: 12,
      int: 10,
      wis: 10,
      cha: 10,
      weapons: [light_crossbow(), scimitar()],
      inventory: [leather()],
      saves: ["dex", "con"]
    )
  end

  @spec skeleton(opts()) :: Character.t()
  def skeleton(opts \\ []) do
    base(opts, "undead", "skeleton", "Clattering bones animated by dark magic.", 13, 13, 30,
      str: 10,
      dex: 14,
      con: 15,
      int: 6,
      wis: 8,
      cha: 5,
      weapons: [shortbow()],
      inventory: [],
      saves: ["con"]
    )
  end

  @spec wolf(opts()) :: Character.t()
  def wolf(opts \\ []) do
    base(opts, "beast", "wolf", "A grey-furred predator with bared fangs.", 11, 13, 40,
      str: 12,
      dex: 15,
      con: 12,
      int: 3,
      wis: 12,
      cha: 6,
      weapons: [bite()],
      inventory: [],
      saves: ["dex"]
    )
  end

  # ----------------------------------------------------------------- CR 1/2

  @spec orc(opts()) :: Character.t()
  def orc(opts \\ []) do
    base(opts, "humanoid", "orc", "A brutish warrior with tusks and a greataxe.", 15, 13, 30,
      str: 16,
      dex: 12,
      con: 16,
      int: 7,
      wis: 11,
      cha: 10,
      weapons: [greataxe()],
      inventory: [hide_armor()],
      saves: ["str", "con"]
    )
  end

  @spec hobgoblin(opts()) :: Character.t()
  def hobgoblin(opts \\ []) do
    base(opts, "goblinoid", "hobgoblin", "A disciplined, armoured goblinoid soldier.", 11, 18, 30,
      str: 13,
      dex: 12,
      con: 12,
      int: 10,
      wis: 10,
      cha: 9,
      weapons: [longsword_ml(), light_crossbow()],
      inventory: [chain_mail()],
      saves: ["con"]
    )
  end

  # ------------------------------------------------------------------- CR 1

  @spec ogre(opts()) :: Character.t()
  def ogre(opts \\ []) do
    base(opts, "giant", "ogre", "A massive, dim-witted brute wielding a tree trunk.", 28, 11, 40,
      str: 19,
      dex: 8,
      con: 16,
      int: 5,
      wis: 7,
      cha: 7,
      weapons: [greatclub()],
      inventory: [hide_armor()],
      saves: ["str", "con"]
    )
  end

  # ------------------------------------------------------------- base builder

  defp base(opts, race, default_name, backstory, hp, ac, speed, stats) do
    {weapons, rest} = Keyword.pop(stats, :weapons, [])
    {inventory, rest} = Keyword.pop(rest, :inventory, [])
    {saves, _} = Keyword.pop(rest, :saves, [])

    %Character{
      name: Keyword.get(opts, :name, default_name),
      race: race,
      class: "monster",
      side: "enemy",
      level: 1,
      str: Keyword.fetch!(stats, :str),
      dex: Keyword.fetch!(stats, :dex),
      con: Keyword.fetch!(stats, :con),
      int: Keyword.fetch!(stats, :int),
      wis: Keyword.fetch!(stats, :wis),
      cha: Keyword.fetch!(stats, :cha),
      hp: hp,
      max_hp: hp,
      temp_hp: 0,
      ac: ac,
      speed: speed,
      backstory: Keyword.get(opts, :backstory, backstory),
      weapons: weapons,
      spells: [],
      inventory: inventory,
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: saves
    }
  end

  # ----------------------------------------------------------- weapons

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

  defp dagger,
    do: %Weapon{
      name: "dagger",
      dice: "1d4",
      damage_type: "piercing",
      attack_ability: :str,
      finesse: true
    }

  defp sling,
    do: %Weapon{
      name: "sling",
      dice: "1d4",
      damage_type: "bludgeoning",
      attack_ability: :dex,
      ranged: true
    }

  defp light_crossbow,
    do: %Weapon{
      name: "light crossbow",
      dice: "1d8",
      damage_type: "piercing",
      attack_ability: :dex,
      ranged: true
    }

  defp bite,
    do: %Weapon{name: "bite", dice: "1d6", damage_type: "piercing", attack_ability: :str}

  defp greataxe,
    do: %Weapon{name: "greataxe", dice: "1d12", damage_type: "slashing", attack_ability: :str}

  defp longsword_ml,
    do: %Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}

  defp greatclub,
    do: %Weapon{name: "greatclub", dice: "1d8", damage_type: "bludgeoning", attack_ability: :str}

  # ----------------------------------------------------------- armor

  defp leather, do: %Item{name: "leather armor", qty: 1, kind: :armor}
  defp shield, do: %Item{name: "shield", qty: 1, kind: :armor}
  defp hide_armor, do: %Item{name: "hide armor", qty: 1, kind: :armor}
  defp chain_mail, do: %Item{name: "chain mail", qty: 1, kind: :armor}

  # ----------------------------------------------------- practice targets

  @doc """
  A straw-and-burlap practice dummy on a wooden post. CA low (12 — easy to
  hit), modest HP, no weapons, no initiative participation worth speaking of.
  Used by `spawn_monster("training_dummy", "maniquí1")` so the DM can materialize
  a target the engine recognizes when a PC wants to swing at the practice rack
  — instead of refusing with "no existe el objetivo" or inventing a roll.
  """
  @spec training_dummy(opts()) :: Character.t()
  def training_dummy(opts \\ []) do
    base(
      opts,
      "construct",
      "monster",
      "A straw-and-burlap practice dummy on a wooden post.",
      20,
      12,
      0,
      str: 3,
      dex: 3,
      con: 10,
      int: 1,
      wis: 1,
      cha: 1,
      weapons: [],
      inventory: [],
      saves: []
    )
  end

  @doc """
  A wooden archery target with concentric-painted rings. CA 15 (smaller
  center), HP generous so it survives many arrows. No weapons.
  """
  @spec archery_target(opts()) :: Character.t()
  def archery_target(opts \\ []) do
    base(
      opts,
      "construct",
      "monster",
      "A wooden archery target with concentric rings.",
      30,
      15,
      0,
      str: 1,
      dex: 1,
      con: 10,
      int: 1,
      wis: 1,
      cha: 1,
      weapons: [],
      inventory: [],
      saves: []
    )
  end
end
