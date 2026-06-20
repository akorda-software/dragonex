defmodule Dragones.Character do
  @moduledoc """
  A PC/NPC sheet, used as a structured-output spec for ExAgent.

  Demonstrates that OutputSchema surfaces changeset constraints to the model:
  ability scores are bounded, HP can't be negative, level is >= 1.
  """

  use Ecto.Schema
  @primary_key false

  embedded_schema do
    field(:name, :string)
    field(:class, :string)
    field(:level, :integer)
    field(:hp, :integer)
    field(:str, :integer)
    field(:dex, :integer)
    field(:con, :integer)
  end

  def changeset(schema, attrs) do
    schema
    |> Ecto.Changeset.cast(attrs, [:name, :class, :level, :hp, :str, :dex, :con])
    |> Ecto.Changeset.validate_required([:name, :class])
    |> Ecto.Changeset.validate_number(:level,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    |> Ecto.Changeset.validate_number(:hp, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:str,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    |> Ecto.Changeset.validate_number(:dex,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
    |> Ecto.Changeset.validate_number(:con,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20
    )
  end
end
