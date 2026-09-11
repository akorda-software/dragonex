defmodule Dragonex.Character do
  @moduledoc """
  A PC/NPC sheet — the engine's live entity and the ExAgent OutputSchema for
  DM-generated sheets.

  Kept as an Ecto embedded schema so the same struct serves two roles:
    * structured output: the changeset surfaces bounds (level 1-20, ability
      scores 1-20, hp >= 0) to the model via OutputSchema;
    * runtime combatant: the Rules layer reads/writes it directly.

  Weapons, spells and inventory are `{:array, :map}` so they can carry
  Weapon/Spell/Item structs at runtime while staying JSON-portable for the
  Session store.
  """

  use Ecto.Schema
  @primary_key false

  @abilities [:str, :dex, :con, :int, :wis, :cha]

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:name, :string)
    field(:race, :string)
    field(:class, :string)
    field(:sex, :string)
    field(:side, :string, default: "pc")
    field(:level, :integer, default: 1)
    field(:xp, :integer, default: 0)

    field(:hp, :integer, default: 0)
    field(:max_hp, :integer, default: 0)
    field(:temp_hp, :integer, default: 0)
    field(:concentrating, :string)
    field(:raging, :boolean, default: false)
    field(:reckless, :boolean, default: false)
    field(:second_wind_used, :boolean, default: false)
    field(:action_surge_used, :boolean, default: false)
    field(:fighting_style, :string)
    field(:smite_slot, :integer)
    field(:lay_on_hands_pool, :integer, default: 0)
    field(:bardic_inspiration_uses, :integer, default: 0)
    field(:inspired, :boolean, default: false)
    field(:arcane_recovery_used, :boolean, default: false)
    field(:divine_sense_uses, :integer, default: 0)
    field(:channel_divinity_used, :boolean, default: false)
    field(:damage_resistances, {:array, :string}, default: [])
    field(:damage_vulnerabilities, {:array, :string}, default: [])
    field(:damage_immunities, {:array, :string}, default: [])
    field(:ac, :integer, default: 10)
    field(:speed, :integer, default: 30)

    field(:str, :integer)
    field(:dex, :integer)
    field(:con, :integer)
    field(:int, :integer)
    field(:wis, :integer)
    field(:cha, :integer)

    field(:backstory, :string)

    field(:weapons, {:array, :map}, default: [])
    field(:spells, {:array, :map}, default: [])
    field(:inventory, {:array, :map}, default: [])
    field(:conditions, {:array, :map}, default: [])
    field(:death_saves, :map, default: %{successes: 0, fails: 0})
    field(:saving_proficiencies, {:array, :string}, default: [])

    # Construido de nivel 1 (ver Dragonex.Heroes):
    #   skill_proficiencies — skills de clase (elegidas) + trasfondo
    #   languages           — idiomas de raza/trasfondo + extra elegidos
    #   racial_traits       — rasgos raciales (claves estables)
    #   class_features      — características de clase a nivel 1
    #   background_feature  — la característica del trasfondo
    field(:skill_proficiencies, {:array, :string}, default: [])
    field(:languages, {:array, :string}, default: [])
    field(:racial_traits, {:array, :string}, default: [])
    field(:class_features, {:array, :string}, default: [])
    field(:background_feature, :string)
  end

  def changeset(schema, attrs) do
    schema
    |> Ecto.Changeset.cast(
      attrs,
      [
        :name,
        :race,
        :class,
        :sex,
        :side,
        :level,
        :xp,
        :hp,
        :max_hp,
        :temp_hp,
        :concentrating,
        :raging,
        :reckless,
        :second_wind_used,
        :action_surge_used,
        :fighting_style,
        :smite_slot,
        :lay_on_hands_pool,
        :bardic_inspiration_uses,
        :inspired,
        :arcane_recovery_used,
        :divine_sense_uses,
        :channel_divinity_used,
        :damage_resistances,
        :damage_vulnerabilities,
        :damage_immunities,
        :ac,
        :speed,
        :str,
        :dex,
        :con,
        :int,
        :wis,
        :cha,
        :backstory,
        :weapons,
        :spells,
        :inventory,
        :conditions,
        :death_saves,
        :saving_proficiencies,
        :skill_proficiencies,
        :languages,
        :racial_traits,
        :class_features,
        :background_feature
      ]
    )
    |> Ecto.Changeset.validate_required([:name, :class])
    |> Ecto.Changeset.validate_number(:level,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    |> Ecto.Changeset.validate_number(:hp, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:max_hp, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:ac, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:smite_slot,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 5
    )
    |> Ecto.Changeset.validate_number(:lay_on_hands_pool, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:bardic_inspiration_uses, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:divine_sense_uses, greater_than_or_equal_to: 0)
    |> validate_abilities()
  end

  defp validate_abilities(changeset) do
    Enum.reduce(@abilities, changeset, fn ability, acc ->
      Ecto.Changeset.validate_number(acc, ability,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: 20
      )
    end)
  end

  @doc "The six ability scores."
  @spec abilities() :: [:str | :dex | :con | :int | :wis | :cha]
  def abilities, do: @abilities

  @doc """
  Build a character with sensible defaults (abilities 10, hp 0, side "pc").
  Unknown keys raise — useful for tests and for spawning monsters/NPCs.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defaults = [
      race: "human",
      class: "commoner",
      sex: nil,
      side: "pc",
      level: 1,
      xp: 0,
      hp: 0,
      max_hp: 0,
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
      damage_resistances: [],
      damage_vulnerabilities: [],
      damage_immunities: [],
      ac: 10,
      speed: 30,
      str: 10,
      dex: 10,
      con: 10,
      int: 10,
      wis: 10,
      cha: 10,
      weapons: [],
      spells: [],
      inventory: [],
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: [],
      skill_proficiencies: [],
      languages: [],
      racial_traits: [],
      class_features: [],
      background_feature: nil
    ]

    struct(__MODULE__, Keyword.merge(defaults, opts))
  end

  @doc "Raw score for an ability."
  @spec score(t(), :str | :dex | :con | :int | :wis | :cha) :: integer() | nil
  def score(%__MODULE__{} = c, ability) when ability in @abilities do
    Map.fetch!(c, ability)
  end

  @doc "Derived modifier for an ability."
  @spec modifier(t(), :str | :dex | :con | :int | :wis | :cha) :: integer()
  def modifier(%__MODULE__{} = c, ability) when ability in @abilities do
    c |> score(ability) |> Dragonex.Rules.Ability.modifier()
  end

  @doc """
  Condition names on the sheet. Accepts the encodings the codec may persist:
  `%{condition: name}`, `%{"condition" => name}`, or a bare string.
  """
  @spec condition_names(t()) :: [String.t()]
  def condition_names(%__MODULE__{conditions: conds}) when is_list(conds) do
    conds
    |> Enum.map(&condition_name/1)
    |> Enum.reject(&is_nil/1)
  end

  def condition_names(_), do: []

  @doc "Extract the name from a single condition entry, or `nil`."
  @spec condition_name(term()) :: String.t() | nil
  def condition_name(%{condition: c}) when is_binary(c), do: c
  def condition_name(%{"condition" => c}) when is_binary(c), do: c
  def condition_name(c) when is_binary(c), do: c
  def condition_name(_), do: nil

  @doc """
  Scale raw damage by immunity / resistance / vulnerability (D38).

  `type` nil or empty → amount unchanged (flat damage). Immunity → 0.
  Resistance and vulnerability to the same type cancel. Resistance alone
  halves (`div/2`); vulnerability alone doubles. Floor 0.
  Tiefling `hellish_resistance` counts as fire resistance without duplicating
  the type in `damage_resistances`. Rage (D42) overlays bludgeoning/piercing/
  slashing resistance while `c.raging` without mutating the persisted lists.
  """
  @spec incoming_damage(t(), integer(), String.t() | nil) :: integer()
  def incoming_damage(%__MODULE__{} = c, amount, type) when is_integer(amount) do
    case normalize_damage_type(type) do
      nil ->
        amount

      t ->
        amount = max(0, amount)

        cond do
          immune_to?(c, t) -> 0
          resistant_to?(c, t) and vulnerable_to?(c, t) -> amount
          resistant_to?(c, t) -> div(amount, 2)
          vulnerable_to?(c, t) -> amount * 2
          true -> amount
        end
    end
  end

  defp immune_to?(%__MODULE__{} = c, type), do: type in list(c.damage_immunities)

  defp vulnerable_to?(%__MODULE__{} = c, type), do: type in list(c.damage_vulnerabilities)

  @rage_resist ~w(bludgeoning piercing slashing)

  defp resistant_to?(%__MODULE__{} = c, type) do
    type in list(c.damage_resistances) or
      (type == "fire" and "hellish_resistance" in list(c.racial_traits)) or
      (c.raging == true and type in @rage_resist)
  end

  defp list(nil), do: []
  defp list(xs) when is_list(xs), do: xs
  defp list(_), do: []

  defp normalize_damage_type(nil), do: nil
  defp normalize_damage_type(""), do: nil

  defp normalize_damage_type(type) when is_binary(type) do
    case String.downcase(String.trim(type)) do
      "" -> nil
      t -> t
    end
  end

  defp normalize_damage_type(_), do: nil
end
