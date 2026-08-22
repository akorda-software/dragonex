defmodule Dragonex.Events do
  @moduledoc """
  ExAgent capability that publishes a beat's intermediate text and tool
  declarations **as they happen**, so the chat timeline fills in live instead of
  collapsing into one block at the end of the beat.

  ## Why this exists

  ExAgent's loop discards the assistant text emitted alongside a tool call (it
  only keeps the text of the *final* tool-free response). For us that means the
  per-action "declarations" — a bot PC saying *"Cubro al herido"* before firing,
  or the DM describing a monster's charge before the attack — were silently
  dropped, which is a big part of why bot turns felt invisible.

  This capability hooks `after_model_request/2`, reads the latest `Response`
  off the run state, and whenever the model produced text it persists an event
  (`:action` for mid-beat declarations, `:narration` for the final wrap-up) and
  broadcasts a PubSub signal so the LiveView re-renders immediately.

  ## Per-beat context

  Capabilities are baked into the agent at construction time, but the values we
  need (game_id, turn_id, actor, round, phase) change every beat. We thread
  them through `state.deps.beat`, which `Dragonex.Game.run_beat/5` populates
  per turn. When `deps.beat` is absent (unit tests of the agent itself) the
  capability is a no-op.
  """

  use ExAgent.Capability

  alias Dragonex.{Games, Text}
  alias ExAgent.Message.Response

  @pubsub Dragonex.PubSub

  @impl true
  def after_model_request(_cap, state) do
    case state.deps do
      %{beat: %{game_id: game_id, actor: actor} = beat} ->
        maybe_publish_speech(game_id, actor, beat, latest_response(state))

      _ ->
        :ok
    end

    state
  end

  # Pull the most recent assistant Response from the run's messages. The loop
  # appends it before invoking `after_model_request`, so it is the last entry.
  defp latest_response(%{messages: messages}) when is_list(messages) do
    Enum.find(Enum.reverse(messages), &match?(%Response{}, &1))
  end

  defp latest_response(_), do: nil

  defp maybe_publish_speech(_game_id, _actor, _beat, nil), do: :ok

  defp maybe_publish_speech(game_id, actor, beat, %Response{} = resp) do
    text =
      resp
      |> Response.text()
      |> String.trim()
      |> Text.scrub(actor,
        pc_names: beat[:pc_names] || [],
        wait_for_human: beat[:wait_for_human] == true
      )

    if text == "" do
      :ok
    else
      # The model's text — mid-beat declarations AND the final wrap-up — is
      # ALWAYS narration. We used to split into :action (mid-beat) vs
      # :narration (final), but :action is reserved for the HUMAN's chat-input
      # text, and rendering DM/bot speech as :action made it show up as a
      # "💭 declared intent" chip in the UI, which looked broken. Now both
      # flow through :narration and the timeline reads as continuous prose
      # from each actor. turn_id is carried so the UI keeps them grouped in
      # the right turn block.
      payload = %{text: text, turn_id: beat.turn_id, round: beat[:round], phase: beat[:phase]}

      {:ok, _} = Games.append_event(game_id, :narration, actor, "all", payload)
      broadcast_updated(game_id)
    end
  end

  defp broadcast_updated(game_id) do
    Phoenix.PubSub.broadcast(@pubsub, "dragonex:game:#{game_id}", {:game_updated, game_id})
  rescue
    _ -> :ok
  end
end
