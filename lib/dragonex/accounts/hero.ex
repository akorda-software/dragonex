defmodule Dragonex.Accounts.Hero do
  @moduledoc """
  A saved character template — the output of the creator (`Dragonex.Heroes.build/1`).

  The `sheet` column stores the `Dragonex.Character` encoded via the same Codec
  path the game layer uses (`Codec.encode` on a single-character world). Loading
  it back (`Codec.decode`) rebuilds the struct for display or game import.
  """

  use Ecto.Schema

  alias Dragonex.Accounts.User

  schema "heroes" do
    belongs_to(:user, User)
    field(:name, :string)
    field(:race, :string)
    field(:class, :string)
    field(:level, :integer, default: 1)
    field(:sheet, :map)
    field(:draft, :map)

    timestamps(type: :naive_datetime)
  end
end
