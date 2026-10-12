defmodule Dragonex.Game.Persistence do
  @moduledoc """
  The Game's durability + fan-out layer: snapshotting the live world to
  Postgres and broadcasting change signals on `Dragonex.PubSub`.

  Extracted from `Dragonex.Game`. These functions run **inside the Game
  GenServer's process** (single-writer, D6) — they are the only code besides
  the Game itself that writes partida state.
  """

  alias Dragonex.{Games, Repo, RollLog}
  require Logger
  alias ExAgent.Session

  @pubsub Dragonex.PubSub

  # Persist the live state to Postgres: world jsonb + turn position + status +
  # the pending intents (so a player's declared plan survives a restart).
  def persist(state, status) do
    world = Session.read_state(state.session)
    persist_world(state, world, status)
  end

  # Also used before an actor tool publishes its candidate to the Session.
  def persist_world(state, world, status) do
    Games.save_state(
      state.game_id,
      world,
      Session.current(state.session),
      world.round,
      status,
      state.intents
    )
  end

  # Prepared dice are private to the tool execution. Save them together with
  # its candidate and replay receipt; never publish a partial SQL transaction.
  # Read after evaluating the change, which can itself produce saving throws.
  # `before` is the world the change ran on, so the rolls can carry the HP
  # they left behind.
  def persist_tool_change(state, world, deps, before \\ nil) do
    entries = deps[:roll_log] |> RollLog.pending() |> RollLog.with_hp_changes(before, world)
    actor = Map.get(deps.beat, :actor, Session.current(state.session))
    metadata = Map.take(deps.beat, [:turn_id, :round, :phase])
    persist_roll_change(state, world, entries, actor, metadata)
  end

  # Automatic engine rolls have no model tool execution but need the same
  # durability boundary. Related system notes belong to that transition too.
  def persist_narration_change(state, world, actor, payload),
    do: persist_roll_change(state, world, [], actor, %{}, [], [{actor, payload}])

  def persist_roll_change(state, world, entries, actor, metadata, notes \\ [], narrations \\ []) do
    Repo.transaction(fn ->
      case persist_world(state, world, state.status) do
        {:ok, %Games.Game{}} -> :ok
        {:ok, nil} -> Repo.rollback(:game_not_found)
      end

      for entry <- entries do
        payload = Map.merge(entry, metadata)

        case Games.append_event(state.game_id, :dice, actor, "all", payload) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      for note <- notes do
        case Games.append_event(state.game_id, :system, "system", "all", note) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      for {speaker, payload} <- narrations do
        case Games.append_event(state.game_id, :narration, speaker, "all", payload) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      entries
    end)
  rescue
    error in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("Rule commit failed for game #{state.game_id}: #{inspect(error.__struct__)}")
      {:error, :persistence_failed}
  end

  # Call only after both SQL and the live Session have accepted the candidate.
  def publish_tool_rolls(state, deps, entries) do
    RollLog.acknowledge(deps[:roll_log], entries)
    publish_rolls(state, entries)
  end

  def publish_rolls(state, entries) do
    Enum.each(entries, &broadcast_roll_group(state.game_id, &1))
    if entries != [], do: broadcast_updated(state)
    :ok
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
