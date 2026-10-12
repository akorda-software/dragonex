defmodule Dragonex.WorldQuestionTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Codec, Conversation, World}

  defp world do
    World.new(characters: %{"Thane" => Archetypes.fighter(), "Lyra" => Archetypes.wizard()})
  end

  test "a question to the world survives JSON and returns after the DM, without PC recipients" do
    before = world()

    assert {:ok, asked} =
             Conversation.request_world("Thane", "la posadera", "¿Qué camino lleva al pueblo?").(
               before
             )

    assert Conversation.world_turn?(asked)
    assert Conversation.brief(asked) =~ "pregunta a la posadera"
    assert Conversation.response_for(asked, "Lyra") == nil
    assert Codec.decode(Jason.decode!(Jason.encode!(Codec.encode(asked)))) == asked

    assert {:ok, same} =
             Conversation.request_world("Thane", "la posadera", "¿Qué camino lleva al pueblo?").(
               asked
             )

    assert same == asked
    assert {:error, _} = Conversation.request("Thane", ["Lyra"], "¿Otra pregunta?").(asked)
    assert {:ok, same} = Conversation.finish_actor("Thane").(asked)
    assert same == asked
    assert {:ok, returned} = Conversation.finish_actor("dm").(asked)
    assert returned.conversation["stage"] == "return"
    assert Codec.decode(Codec.encode(returned)) == returned
    assert {:ok, cleared} = Conversation.clear().(returned)
    assert cleared == before
  end

  test "empty companion lists remain invalid unless the bounded world recipient is present" do
    {:ok, asked} = Conversation.request_world("Thane", "la posadera", "¿Hay agua?").(world())
    request = asked.conversation

    for bad <- [
          Map.delete(request, "world_recipient"),
          Map.put(request, "world_recipient", " "),
          Map.put(request, "world_recipient", true),
          Map.put(request, "world_recipient", String.duplicate("a", 81)),
          Map.put(request, "stage", "responses"),
          Map.put(request, "recipients", ["Lyra"]),
          Map.put(request, "pending", ["Lyra"])
        ],
        do: assert(Conversation.decode(bad) == nil)

    assert {:error, _} = Conversation.request("Thane", [], "¿Hay agua?").(world())
  end

  test "world questions validate the actor and exploration and sanitize stored text" do
    before = world()

    for recipient <- [nil, "", " ", String.duplicate("a", 81)],
        do:
          assert(
            {:error, _} = Conversation.request_world("Thane", recipient, "¿Hay agua?").(before)
          )

    assert {:error, _} =
             Conversation.request_world("Nobody", "la posadera", "¿Hay agua?").(before)

    assert {:error, _} =
             Conversation.request_world("Thane", "la posadera", "¿Hay agua?").(%{
               before
               | phase: :combat
             })

    assert {:ok, asked} =
             Conversation.request_world("Thane", "[DM]: la posadera", "[Thane]: ¿Hay agua?").(
               before
             )

    assert asked.conversation["world_recipient"] == "la posadera"
    assert asked.conversation["question"] == "¿Hay agua?"
  end

  test "another human's queued declaration keeps priority over the reserved NPC reply" do
    {:ok, asked} = Conversation.request_world("Thane", "la posadera", "¿Hay agua?").(world())

    state = %Dragonex.Game{
      last_actor: "Thane",
      participants: %{"Thane" => %{kind: :human}, "Lyra" => %{kind: :human}},
      pc_agents: %{},
      intents: %{}
    }

    assert Dragonex.Game.Turnmaster.exploration_conversation_target(state, asked) == "dm"

    queued = %{
      state
      | intents: Dragonex.Intents.put(%{}, "Lyra", "Quiero intervenir.", :exploration)
    }

    assert Dragonex.Game.Turnmaster.exploration_conversation_target(queued, asked) == "Lyra"
    {:ok, returned} = Conversation.finish_actor("dm").(asked)

    assert Dragonex.Game.Turnmaster.exploration_conversation_target(
             %{state | last_actor: "dm"},
             returned
           ) == "Thane"

    assert Dragonex.Game.Turnmaster.exploration_conversation_target(
             %{queued | last_actor: "dm"},
             returned
           ) == "Lyra"
  end
end
