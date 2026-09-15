defmodule Dragonex.Monsters do
  @moduledoc """
  Prebuilt foes for the DM to spawn. Canonical 5e SRD stats, `side: "enemy"` so
  the WorldDriven policy folds them onto the DM's turn (the DM acts for its
  monsters when their slot in the initiative order comes up).

  Each monster is CR-rated so the DM can gauge encounter difficulty:
    * CR 0:   cat
    * CR 1/4: goblin, kobold, bandit, skeleton, wolf
    * CR 1/2: orc, hobgoblin, black bear
    * CR 1:   ogre, giant spider (D75 — the engine's only poison source)

  The beast keys with CR ≤ 1/2 are also the Wild Shape catalogue (D63):
  see `wild_shape_beasts/0`.
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
      "cat" => &cat/1,
      "black_bear" => &black_bear/1,
      "orc" => &orc/1,
      "hobgoblin" => &hobgoblin/1,
      "ogre" => &ogre/1,
      "giant_spider" => &giant_spider/1,
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
      saves: ["con"],
      damage_vulnerabilities: ["bludgeoning"],
      damage_immunities: ["poison"]
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

  # ------------------------------------------------------------- beasts (D63)

  @doc """
  All beast forms available to Wild Shape (D63) as `%{key => cr}` (cr float).

  Gate: druid L2–3 → max 0.25 (cat, wolf); L4+ → max 0.5 (all). No flying
  or swimming speed forms (out of scope by design).
  """
  @spec wild_shape_beasts() :: %{String.t() => float()}
  def wild_shape_beasts, do: %{"cat" => 0.0, "wolf" => 0.25, "black_bear" => 0.5}

  @doc "Cat (CR 0, D63 Wild Shape form): tiny, fast, harmless."
  @spec cat(opts()) :: Character.t()
  def cat(opts \\ []) do
    base(opts, "beast", "cat", "A tiny tabby cat with sharp senses.", 4, 12, 40,
      str: 3,
      dex: 15,
      con: 10,
      int: 3,
      wis: 12,
      cha: 7,
      weapons: [cat_bite()],
      inventory: [],
      saves: []
    )
  end

  @doc "Black bear (CR 1/2, D63 Wild Shape form): a stocky, powerful omnivore."
  @spec black_bear(opts()) :: Character.t()
  def black_bear(opts \\ []) do
    base(opts, "beast", "black bear", "A powerfully built black-furred bear.", 19, 11, 40,
      str: 15,
      dex: 14,
      con: 14,
      int: 2,
      wis: 12,
      cha: 7,
      weapons: [bear_bite()],
      inventory: [],
      saves: []
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

  @doc """
  Giant spider (CR 1, D75): the classic venomous beast — the engine's first
  real POISON damage source, so resistances like Dwarven Resilience (D76)
  have a measurable effect. RAW bite is 1d8+3 piercing PLUS 2d8 poison
  (CON save DC 11 for half); the engine models ONE damage type per weapon,
  so it is combined into a single "3d8+3 poison" total (documented
  simplification, ADR D75). The dice stay bare "3d8" because
  `Combat.damage_roll` adds the DEX modifier (+3) on top — weapon dice
  only parse `NdM` — and DEX also gives the RAW +5 to hit (prof 2 + 3).
  No web or wall-crawling (out of scope: no positioning).
  """
  @spec giant_spider(opts()) :: Character.t()
  def giant_spider(opts \\ []) do
    base(
      opts,
      "beast",
      "giant spider",
      "A horse-sized spider with venom-dripping fangs.",
      26,
      14,
      30,
      str: 15,
      dex: 16,
      con: 12,
      int: 2,
      wis: 12,
      cha: 7,
      weapons: [spider_bite()],
      inventory: [],
      saves: ["dex"]
    )
  end

  # ------------------------------------------------------------- base builder

  defp base(opts, race, default_name, backstory, hp, ac, speed, stats) do
    {weapons, rest} = Keyword.pop(stats, :weapons, [])
    {inventory, rest} = Keyword.pop(rest, :inventory, [])
    {saves, rest} = Keyword.pop(rest, :saves, [])
    {resist, rest} = Keyword.pop(rest, :damage_resistances, [])
    {vuln, rest} = Keyword.pop(rest, :damage_vulnerabilities, [])
    {immune, _} = Keyword.pop(rest, :damage_immunities, [])

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
      concentrating: nil,
      raging: false,
      reckless: false,
      second_wind_used: false,
      action_surge_used: false,
      fighting_style: nil,
      smite_slot: nil,
      lay_on_hands_pool: 0,
      bardic_inspiration_uses: 0,
      inspired: false,
      arcane_recovery_used: false,
      divine_sense_uses: 0,
      channel_divinity_used: false,
      ki: 0,
      sorcery_points: 0,
      damage_resistances: resist,
      damage_vulnerabilities: vuln,
      damage_immunities: immune,
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

  defp cat_bite,
    do: %Weapon{
      name: "bite",
      dice: "1d4",
      damage_type: "piercing",
      attack_ability: :str,
      finesse: true
    }

  defp bear_bite,
    do: %Weapon{name: "bite", dice: "1d8+3", damage_type: "piercing", attack_ability: :str}

  # D75: bare "3d8" + the DEX modifier the engine adds = "3d8+3" poison
  # total (see `giant_spider/1`). Weapon dice only parse NdM.
  defp spider_bite,
    do: %Weapon{name: "bite", dice: "3d8", damage_type: "poison", attack_ability: :dex}

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
