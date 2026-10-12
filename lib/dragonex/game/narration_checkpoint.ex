defmodule Dragonex.Game.NarrationCheckpoint do
  @moduledoc """
  Saves public speech and its actor receipt in one SQL transaction, before
  publishing the checkpoint to Session or acknowledging the tool/result.
  Only Game calls this writer. Rules, resources and RNG remain unchanged.
  """
  alias Dragonex.Events
  alias Dragonex.Game.{Beat, Persistence, ToolReplay}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  def commit(
        %{busy: %Beat{kind: :actor} = beat} = state,
        %{
          state: %SharedState{session: session, participant_id: actor},
          beat: %{game_id: game_id, actor: actor, turn_id: turn_id},
          beat_owner: owner
        } = deps,
        raw,
        complete
      )
      when session == state.session and game_id == state.game_id and
             actor == beat.participant and turn_id == beat.turn_id and is_pid(owner) do
    if Process.alive?(owner) and Session.current(session) == actor do
      with {:ok, text, payload} <- Events.prepare_speech(deps, raw, complete) do
        world = Session.read_state(session)
        {next, candidate} = ToolReplay.stage_narration(state, deps, world)

        with {:ok, []} <- Persistence.persist_narration_change(state, candidate, actor, payload),
             {:ok, _} <- Session.update_state(session, actor, fn _ -> {:ok, candidate} end) do
          Persistence.broadcast_updated(next)
          {{:ok, text}, next}
        else
          {:error, _} = error -> {error, state}
        end
      else
        {:error, _} = error -> {error, state}
      end
    else
      {{:error, :cancelled}, state}
    end
  end

  def commit(state, _deps, _raw, _complete), do: {{:error, :stale_beat}, state}
end
