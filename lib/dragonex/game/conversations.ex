defmodule Dragonex.Game.Conversations do
  @moduledoc """
  Exploration response bookkeeping inside the Game single-writer process.
  The durable queue lives in World; no ephemeral cursor is needed on restart.
  """

  alias Dragonex.{Conversation, Games, Text}
  alias Dragonex.Game.{ConversationClosure, Participants, Persistence}
  alias ExAgent.Session

  def literal_pc_speech(state, actor, text, world) when is_binary(text) do
    case world.conversation do
      %{
        "from" => ^actor,
        "stage" => "responses",
        "recipients" => recipients,
        "pending" => pending,
        "question" => question
      }
      when recipients == pending ->
        if world.phase == :exploration and Participants.human?(state, actor) and
             not Participants.ai_pc?(state, actor) and not state.tm_reeval and
             not state.pending_mini and not state.last_was_mini and
             state.interrupted in [nil, ""] and question == Text.scrub(String.trim(text)) and
             Text.explicit_pc_recipients(text, recipients, Map.keys(world.characters)) ==
               recipients do
          Text.literal_pc_speech(text, recipients, Map.keys(world.characters))
        end

      _ ->
        nil
    end
  end

  def literal_pc_speech(_, _, _, _), do: nil

  # Only registered, purely spoken manual questions can skip the human model.
  # Extra actions retain the normal tools/resolution beat; the durable request
  # must still match this actual declaration, rather than a previous exchange.
  def literal_npc_speech(state, actor, text, world) do
    case world.conversation do
      %{"from" => ^actor, "stage" => "world", "world_recipient" => _, "question" => question} ->
        if world.phase == :exploration and Participants.human?(state, actor) and
             not Participants.ai_pc?(state, actor) and not state.tm_reeval and
             not state.pending_mini and not state.last_was_mini and
             state.interrupted in [nil, ""] and question == Text.scrub(String.trim(text)) do
          Text.literal_npc_speech(text, pc_names: Participants.pc_names(world))
        end

      _ ->
        nil
    end
  end

  # Consume only an actual human turn, not an off-turn/paused draft. A literal
  # vocative or a qualified NPC question must not depend on the narrator
  # remembering request_response. The latter reserves only DM + human return.
  # An existing exchange stays authoritative while its recipients answer.
  def register_declared_question(state, actor, text, world) do
    if world.phase == :exploration and Map.get(world, :conversation) == nil and
         Participants.human?(state, actor) do
      names =
        Participants.pc_names(world)
        |> Enum.filter(&Map.has_key?(state.participants, &1))
        |> List.delete(actor)

      recipients = Text.explicit_pc_recipients(text, names, Map.keys(world.characters))

      change =
        if recipients == [] do
          case Text.explicit_npc_question(text, pc_names: Participants.pc_names(world)) do
            nil -> nil
            recipient -> Conversation.request_world(actor, recipient, text)
          end
        else
          Conversation.request(actor, recipients, text)
        end

      if change do
        action = state.game_id |> Games.recent_events(1) |> List.last()

        change = fn before ->
          with {:ok, registered} <- change.(before) do
            {:ok, ConversationClosure.reserve(state, actor, text, before, registered, action)}
          end
        end

        case Session.update_state(
               state.session,
               actor,
               change
             ) do
          {:ok, updated} ->
            {:ok, _} = Persistence.persist(state, state.status)
            updated

          _ ->
            world
        end
      else
        world
      end
    else
      world
    end
  end

  # A paused request may reopen directly on a recipient that can no longer
  # answer. Prune before launching any actor, while preserving an unrelated
  # human's already granted intervention.
  def prepare_actor(state) do
    world = Session.read_state(state.session)
    previous_target = target(state, world)

    if previous_target do
      prune = Conversation.prune(Map.keys(state.participants))
      {:ok, pruned} = prune.(world)

      if pruned.conversation != Map.get(world, :conversation) do
        current = Session.current(state.session)

        case Session.update_state(state.session, current, prune) do
          {:ok, pruned} ->
            next = target(state, pruned) || "dm"

            if current == previous_target and current != next,
              do: {state, next},
              else: {state, nil}

          _ ->
            {state, nil}
        end
      else
        {state, nil}
      end
    else
      {state, nil}
    end
  end

  def finish_beat(state, _actor, true), do: state

  def finish_beat(state, actor, false) do
    world = Session.read_state(state.session)

    if Map.get(world, :conversation) do
      proposer = Session.current(state.session)
      names = Map.keys(state.participants)

      closing_events =
        case world.conversation do
          %{"quiet_close" => %{}, "stage" => "responses", "pending" => [^actor]} ->
            Games.recent_events(state.game_id, 400)

          _ ->
            []
        end

      _ =
        Session.update_state(state.session, proposer, fn world ->
          with {:ok, world} <- Conversation.finish_actor(actor).(world),
               {:ok, world} <- Conversation.prune(names).(world),
               {:ok, world} <- ConversationClosure.finish(state, world, closing_events) do
            # An AI questioner does not get another automatic turn just to ask
            # again. The world closed the exchange; normal D28/D30 takes over.
            case world.conversation do
              %{"stage" => "return", "from" => from} ->
                if Participants.human?(state, from),
                  do: {:ok, world},
                  else: Conversation.clear().(world)

              _ ->
                {:ok, world}
            end
          end
        end)
    end

    state
  end

  # Re-evaluations and mini-turn returns retain their existing orchestration.
  # A pending human declaration is prioritized by Turnmaster over this target.
  def target(state, world) do
    if world.phase == :exploration and not state.tm_reeval and not state.pending_mini and
         not state.last_was_mini and state.interrupted in [nil, ""] do
      case Map.get(world, :conversation) do
        %{"stage" => "responses", "pending" => [name | _]} -> name
        %{"stage" => "world"} -> "dm"
        %{"stage" => "return", "from" => from} -> from
        _ -> nil
      end
    end
  end

  def returned(state, name) do
    case state.session |> Session.read_state() |> Map.get(:conversation) do
      %{"stage" => "return", "from" => ^name} ->
        _ = Session.update_state(state.session, name, Conversation.clear())
        state

      _ ->
        state
    end
  end
end
