defmodule Dragonex.Game.Persistence do
  @moduledoc """
  The Game's durability + fan-out layer: snapshotting the live world to
  Postgres and broadcasting change signals on `Dragonex.PubSub`.

  Extracted from `Dragonex.Game`. These functions run **inside the Game
  GenServer's process** (single-writer, D6) — they are the only code besides
  the Game itself that writes partida state.
  """

  alias Dragonex.Games
  alias ExAgent.Session

  @pubsub Dragonex.PubSub

  # Persist the live state to Postgres: world jsonb + turn position + status +
  # the pending intents (so a player's declared plan survives a restart).
  def persist(state, status) do
    world = Session.read_state(state.session)

    Games.save_state(
      state.game_id,
      world,
      Session.current(state.session),
      world.round,
      status,
      state.intents
    )
  end

  # The Game owns a single "something changed" signal on Dragonex.PubSub. The
  # LiveView subscribes and re-fetches the snapshot — it never polls and never
  # touches the Repo directly. Topic is per partida.
  def topic(game_id), do: "dragonex:game:#{game_id}"

  # Broadcast that the partida changed (beat finished, status flip, human acted).
  # Best-effort: a pubsub hiccup must never break the loop.
  def broadcast_updated(%Dragonex.Game{game_id: game_id}) do
    Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:game_updated, game_id})
  rescue
    _ -> :ok
  end

  def broadcast_updated(game_id) when is_integer(game_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:game_updated, game_id})
  rescue
    _ -> :ok
  end

  # One roll group landed just now (RollLog on_close). Push it to the dice modal
  # immediately with the full labeled entry (reason + dice + total + against +
  # outcome) so the modal opens exactly once per roll, with everything in one
  # shot — not the bare-number-then-context two-step we used to have.
  def broadcast_roll_group(game_id, entry) do
    Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:dice_group, game_id, entry})
  rescue
    _ -> :ok
  end
end
