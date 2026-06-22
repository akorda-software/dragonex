defmodule Dragones.Games.Character do
  @moduledoc """
  A roster entry: a `Dragones.Character` sheet frozen at game creation.

  This is the *static baseline* (race, class, abilities, gear) — the source of
  truth for who is in the game and who plays them. The *live* combat state (hp,
  initiative, conditions) lives in `games.world` (jsonb via Codec), which the
  Game mutates during play. Keeping the baseline separate lets the wizard (Fase
  1) edit lineups without touching the live world.
  """

  use Ecto.Schema

  schema "characters" do
    belongs_to(:game, Dragones.Games.Game)
    field(:name, :string)
    field(:sheet, :map)
    field(:kind, Ecto.Enum, values: [:ai, :human], default: :human)

    timestamps(type: :naive_datetime)
  end
end
