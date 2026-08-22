defmodule Dragonex.Games.GameEvent do
  @moduledoc """
  An append-only entry in a game's timeline.

  The `game_events` log is the single replayable history of a partida: every
  narration, player action, tool resolution, die roll and system note, in order.
  It serves three purposes: (a) replay/debug, (b) the chat narrative line (the
  LiveView renders `:visible_to :all` entries), and (c) agent context (recent
  events seed each agent's prompt). Append-only by convention; the only
  deletion is `Games.delete_narrations_for_turn/2` (wipe a truncated
  max_tokens draft before retry). `seq` is monotonic per game.
  """

  use Ecto.Schema

  @type etype :: :narration | :action | :tool | :dice | :system | :turn
  @type visible_to :: :all | :dm | String.t()

  schema "game_events" do
    belongs_to(:game, Dragonex.Games.Game)
    field(:seq, :integer)
    field(:type, Ecto.Enum, values: [:narration, :action, :tool, :dice, :system, :turn])
    field(:actor, :string)
    field(:visible_to, :string, default: "all")
    field(:payload, :map, default: %{})

    timestamps(type: :naive_datetime, updated_at: false)
  end
end
