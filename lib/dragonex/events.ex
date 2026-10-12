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
  off the run state, and whenever the model produced text it persists a
  `:narration` event (intermediate speech and final wrap-up) and
  broadcasts a PubSub signal so the LiveView re-renders immediately.

  Runs with output_type Dragonex.Narration use explicit validated publication
  via Narration.Contract instead. Their free response text stays private and
  unchanged in the native continuation, including corrective output retries.

  Literal human NPC questions can use `publish_speech/3` without a model
  request. General manual actions still run the resolver's tools, but their
  voice comes from the durable declaration in deps.beat.human_declaration.
  Model text is removed from that response without changing native tool parts
  or metadata. Only a completed, nonempty response publishes the source once.

  ## Per-beat context

  Capabilities are baked into the agent at construction time, but the values we
  need (game_id, turn_id, actor, round, phase) change every beat. We thread
  them through `state.deps.beat`, which `Dragonex.Game.run_beat/5` populates
  per turn. When `deps.beat` is absent (unit tests of the agent itself) the
  capability is a no-op.

  Character names are refreshed from SharedState before publishing speech.
  If a tool changes the roster, the next model request also refreshes the
  table before new text deltas arrive, preserving newly registered voices.

  A nonempty, tool-free response carries `complete: true` unless the provider
  reports truncation or filtering. Recovery can then settle the same durable
  actor checkpoint without requesting or publishing its final speech again.
  Intermediate and legacy speech never imply that the beat has finished.
  A locally published literal question is complete speech; its pending NPC
  conversation still proceeds through the usual beat settlement and handoff.
  """

  use ExAgent.Capability

  alias Dragonex.{Games, Text, World}
  alias Dragonex.Game.Participants
  alias ExAgent.Message.Response
  alias ExAgent.Message.Part
  alias ExAgent.Session.SharedState

  @pubsub Dragonex.PubSub

  @impl true
  def before_model_request(_cap, %{deps: %{beat: %{game_id: game_id} = beat} = deps} = state) do
    Dragonex.I18n.adopt(deps)
    current = live_context(beat, deps)

    if current != beat do
      broadcast_updated(game_id)
      %{state | deps: Map.put(deps, :beat, current)}
    else
      state
    end
  end

  def before_model_request(_cap, state), do: state

  @impl true
  def after_model_request(_cap, %{agent: %{output_type: Dragonex.Narration}} = state), do: state

  def after_model_request(_cap, state) do
    state = preserve_human_voice(state)

    case state.deps do
      %{beat: %{game_id: game_id, actor: actor} = beat} ->
        if Dragonex.Game.RunLifecycle.alive?(state.deps) and
             not Dragonex.Game.WaitResolution.waiting?(state.deps) and
             not Dragonex.Game.NPCMemoryResolution.waiting?(state.deps) and
             not Dragonex.Game.InventoryResolution.waiting?(state.deps) do
          maybe_publish_speech(game_id, actor, beat, latest_response(state), state.deps)
        end

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

  defp maybe_publish_speech(_game_id, _actor, _beat, nil, _deps), do: :ok

  defp maybe_publish_speech(game_id, actor, beat, %Response{} = resp, deps) do
    complete = complete_response?(resp)

    # Intermediate/truncated resolver text is not a human declaration or a
    # completion receipt. Native tool parts remain in the run unchanged.
    if is_nil(human_declaration(beat)) or complete do
      publish_speech(
        Map.put(deps, :beat, Map.merge(beat, %{game_id: game_id, actor: actor})),
        Response.text(resp),
        complete
      )
    end
  end

  defp preserve_human_voice(%{deps: %{beat: beat}, messages: messages} = state) do
    case {human_declaration(beat), List.last(messages)} do
      {text, %Response{} = response} when is_binary(text) ->
        complete = complete_response?(response)

        parts = Enum.reject(response.parts, &match?(%Part.Text{}, &1))
        parts = if complete, do: parts ++ [%Part.Text{content: text}], else: parts
        %{state | messages: List.replace_at(messages, -1, %{response | parts: parts})}

      _ ->
        state
    end
  end

  defp preserve_human_voice(state), do: state

  defp complete_response?(response),
    do:
      Response.tool_calls(response) == [] and
        response.finish_reason not in [:length, :content_filter, :unknown, :incomplete, :error] and
        String.trim(Response.text(response)) != ""

  defp human_declaration(%{human_declaration: text}) when is_binary(text) and text != "",
    do: text |> Text.sanitize_utf8() |> String.trim()

  defp human_declaration(_), do: nil

  @doc "Publish speech; durable manual input keeps its words, model text uses roster-aware sanitization."
  def publish_speech(deps, raw, complete) when is_binary(raw) and is_boolean(complete) do
    do_publish_speech(deps, raw, complete)
    :ok
  end

  @doc "Publish final speech and return the actual public text, or why nothing was published."
  def publish_completed_speech(deps, raw) when is_binary(raw),
    do: do_publish_speech(deps, raw, true)

  @doc "Publish explicit intermediate speech without completing the actor beat."
  def publish_intermediate_speech(deps, raw) when is_binary(raw),
    do: do_publish_speech(deps, raw, false)

  defp do_publish_speech(%{game_owner: owner} = deps, raw, complete) when is_pid(owner) do
    if Process.alive?(owner),
      do: GenServer.call(owner, {:publish_narration, deps, raw, complete}),
      else: {:error, :cancelled}
  end

  defp do_publish_speech(%{beat: %{game_id: game_id, actor: actor}} = deps, raw, complete) do
    with {:ok, text, payload} <- prepare_speech(deps, raw, complete),
         {:ok, _} <- Games.append_event(game_id, :narration, actor, "all", payload) do
      broadcast_updated(game_id)
      {:ok, text}
    end
  end

  @doc "Prepare sanitized speech without publication or a World write."
  def prepare_speech(%{beat: %{actor: actor} = beat} = deps, raw, complete)
      when is_binary(raw) and is_boolean(complete) do
    beat = live_context(beat, deps)

    # Typed player input is already an intent, not model prose. Preserve its
    # words (including mentions of others and dice); only repair UTF-8. Every
    # model-origin speech still goes through the roster-aware Text.scrub.
    text =
      human_declaration(beat) ||
        raw
        |> String.trim()
        |> Text.scrub(actor,
          pc_names: beat[:pc_names] || [],
          character_names: beat[:character_names] || [],
          wait_for_human: beat[:wait_for_human] == true
        )

    cond do
      text == "" ->
        {:error, :empty_speech}

      not Dragonex.Game.RunLifecycle.alive?(deps) ->
        {:error, :cancelled}

      true ->
        # Speech — literal human questions, model declarations and the final
        # wrap-up — is ALWAYS narration. We used to split into :action (mid-beat) vs
        # :narration (final), but :action is reserved for the HUMAN's chat-input
        # text, and rendering DM/bot speech as :action made it show up as a
        # "💭 declared intent" chip in the UI, which looked broken. Now both
        # flow through :narration and the timeline reads as continuous prose
        # from each actor. turn_id is carried so the UI keeps them grouped in
        # the right turn block.
        payload = %{
          text: text,
          turn_id: beat.turn_id,
          round: beat[:round],
          phase: beat[:phase],
          complete: complete
        }

        payload =
          if human_declaration(beat),
            do: Map.put(payload, :kind, :human_declaration),
            else: payload

        {:ok, text, payload}
    end
  end

  # A previous tool response may have registered a character during this same
  # beat. Resolve names against the committed World before persisting speech;
  # the construction snapshot is only a fallback for standalone/test runners.
  defp live_context(beat, %{state: %SharedState{} = shared}) do
    case SharedState.read(shared) do
      %World{} = world ->
        Map.merge(beat, %{
          pc_names: Participants.pc_names(world),
          character_names: Map.keys(world.characters)
        })

      _ ->
        beat
    end
  catch
    :exit, _ -> beat
  end

  defp live_context(beat, _deps), do: beat

  defp broadcast_updated(game_id) do
    Phoenix.PubSub.broadcast(@pubsub, "dragonex:game:#{game_id}", {:game_updated, game_id})
  rescue
    _ -> :ok
  end
end
