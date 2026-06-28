defmodule Dragones.Character do
  @moduledoc """
  A PC/NPC sheet — the engine's live entity and the ExAgent OutputSchema for
  DM-generated sheets.

  Kept as an Ecto embedded schema so the same struct serves two roles:
    * structured output: the changeset surfaces bounds (level 1-20, ability
      scores 1-20, hp >= 0) to the model via OutputSchema;
    * runtime combatant: the Rules layer reads/writes it directly.

  Weapons, spells and inventory are `{:array, :map}` so they can carry
  Weapon/Spell/Item structs at runtime while staying JSON-portable for the
  Session store (see FINDINGS.md gap #1).
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

    field(:hp, :integer, default: 0)
    field(:max_hp, :integer, default: 0)
    field(:temp_hp, :integer, default: 0)
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
        :hp,
        :max_hp,
        :temp_hp,
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
        :saving_proficiencies
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
      hp: 0,
      max_hp: 0,
      temp_hp: 0,
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
      saving_proficiencies: []
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
    c |> score(ability) |> Dragones.Rules.Ability.modifier()
  end
end
