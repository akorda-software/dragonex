defmodule Dragonex.Game.RuleCheckpoint do
  @moduledoc """
  Commits an actor tool's world change inside the Game process. Saves the
  candidate before publishing it to the live Session or acknowledging the
  tool, so an interrupted narration cannot rewind an acknowledged effect.
  """

  alias Dragonex.World
  alias Dragonex.Game.{Beat, Persistence}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  def commit(
        %{busy: %Beat{kind: :actor} = busy} = state,
        %{
          state: %SharedState{session: session, participant_id: actor},
          beat: %{game_id: game_id, turn_id: turn_id},
          beat_owner: owner
        } = deps,
        change
      )
      when session == state.session and game_id == state.game_id and
             actor == busy.participant and turn_id == busy.turn_id and is_pid(owner) do
    if Process.alive?(owner) and Session.current(session) == actor do
      before = Session.read_state(session)

      with {:ok, candidate} <- evaluate(change, before) do
        {next, candidate} = Dragonex.Game.ToolReplay.stage_change(state, deps, candidate)

        with {:ok, entries} <- Persistence.persist_tool_change(state, candidate, deps, before),
             {:ok, committed} <-
               Session.update_state(session, actor, fn _ -> {:ok, candidate} end) do
          Persistence.publish_tool_rolls(state, deps, entries)
          Persistence.broadcast_updated(state)
          {{:ok, committed}, next}
        else
          {:error, _} = error -> {error, state}
        end
      else
        {:error, _} = error -> {error, state}
      end
    else
      {{:error, :not_your_turn}, state}
    end
  end

  def commit(state, _deps, _change), do: {{:error, :stale_beat}, state}

  defp evaluate(change, world) do
    case change.(world) do
      {:ok, %World{} = candidate} -> {:ok, candidate}
      %World{} = candidate -> {:ok, candidate}
      {:error, _} = error -> error
      _ -> {:error, :invalid_world_change}
    end
  rescue
    _ -> {:error, :invalid_world_change}
  end
end
