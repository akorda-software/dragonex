defmodule Dragonex.Game.ConversationClosure do
  @moduledoc """
  Read-only proof that a completed PC exchange needs no world response.
  Game reserves the proof with the original action and revalidates it inside
  its settlement mutation. Unknown, changed or incomplete exchanges retain DM.
  """

  alias Dragonex.{Codec, Conversation, Text, World}
  alias Dragonex.Game.Participants

  def reserve(state, actor, text, before, registered, action) do
    request = registered.conversation

    if manual?(state, actor) and before.phase == :exploration and
         not before.scene_refresh_pending and before.conversation == nil and
         matching_question?(request, actor, text, registered) and
         action_matches?(action, actor, request["question"]) do
      put_in(registered.conversation["quiet_close"], %{
        "world_fingerprint" => fingerprint(before),
        "action_seq" => action.seq
      })
    else
      registered
    end
  end

  def fingerprint(%World{} = world) do
    world
    |> Codec.encode()
    |> Map.drop(["conversation", "actor_checkpoint"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def finish(state, world, events) do
    if eligible?(state, world, events),
      do: Conversation.finish_actor("dm").(world),
      else: {:ok, world}
  end

  defp eligible?(state, %{phase: :exploration, scene_refresh_pending: false} = world, events) do
    case world.conversation do
      %{
        "stage" => "world",
        "pending" => [],
        "from" => from,
        "recipients" => recipients,
        "question" => question,
        "quiet_close" => %{"world_fingerprint" => expected, "action_seq" => seq}
      } = request ->
        manual?(state, from) and state.intents == %{} and
          is_nil(request["world_recipient"]) and recipients != [] and
          expected == fingerprint(world) and
          Text.pc_question_only?(question, recipients, Map.keys(world.characters)) and
          clean_exchange?(events, seq, from, recipients, question)

      _ ->
        false
    end
  end

  defp eligible?(_, _, _), do: false

  defp manual?(state, from) do
    Participants.human?(state, from) and not Participants.ai_pc?(state, from) and
      not state.tm_reeval and not state.pending_mini and not state.last_was_mini and
      state.interrupted in [nil, ""]
  end

  defp matching_question?(
         %{
           "from" => from,
           "recipients" => names,
           "pending" => names,
           "stage" => "responses",
           "question" => question
         } = request,
         actor,
         text,
         world
       ) do
    from == actor and is_nil(request["world_recipient"]) and
      question == Text.scrub(String.trim(text)) and
      Text.explicit_pc_recipients(text, names, Map.keys(world.characters)) == names and
      Text.pc_question_only?(text, names, Map.keys(world.characters))
  end

  defp matching_question?(_, _, _, _), do: false

  defp action_matches?(
         %{type: :action, actor: actor, seq: seq, payload: payload},
         from,
         question
       ),
       do: actor == from and is_integer(seq) and seq > 0 and payload["text"] == question

  defp action_matches?(_, _, _), do: false

  defp clean_exchange?(events, seq, from, recipients, question) do
    case Enum.drop_while(events, &(&1.seq < seq)) do
      [action | rest] ->
        action.seq == seq and action_matches?(action, from, question) and
          Enum.all?(rest, &safe_event?(&1, recipients)) and
          Enum.map(Enum.filter(rest, &(&1.type == :narration)), & &1.actor) == [from | recipients]

      _ ->
        false
    end
  end

  defp safe_event?(
         %{type: :narration, actor: actor, payload: %{"complete" => true, "text" => text}},
         names
       )
       when is_binary(text),
       do:
         String.trim(text) != "" and
           (actor not in names or not String.contains?(text, ["¿", "?"]))

  defp safe_event?(%{type: :turn, actor: actor, payload: %{"phase" => "exploration"}}, names),
    do: actor in names

  defp safe_event?(%{type: :system, payload: %{"kind" => "give_turn_to", "to" => to}}, names),
    do: to in names

  defp safe_event?(_, _), do: false
end
