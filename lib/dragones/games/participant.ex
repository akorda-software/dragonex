defmodule Dragones.Games.Participant do
  @moduledoc """
  An actor in a game's turn order: the DM plus each player character.

  `kind` is `:ai` (the Game auto-runs its turns in a Task) or `:human` (the
  Game idles in `:waiting` until the human acts via the LiveView). `side` is the
  D&D allegiance — `"dm"` for the DM, `"pc"` for a player's character. The
  `Dragones.TurnPolicy.WorldDriven` policy maps every non-PC in the world onto
  the DM's single turn, so only the DM + each PC need a row here.
  """

  use Ecto.Schema

  @type kind :: :ai | :human

  schema "participants" do
    belongs_to(:game, Dragones.Games.Game)
    field(:name, :string)
    field(:kind, Ecto.Enum, values: [:ai, :human], default: :human)
    field(:side, :string, default: "pc")

    timestamps(type: :naive_datetime)
  end
end
