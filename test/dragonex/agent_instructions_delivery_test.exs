defmodule Dragonex.AgentInstructionsDeliveryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, DM, Game, Games, History, PCAgent}
  alias ExAgent.{Message, Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the actual Game DM request carries its rules and bible before the shared history" do
    {:ok, game} =
      Games.create_game(
        title: "Una biblia enviada",
        scene: "el muelle",
        story_bible: %{"hook" => "La barquera espera una respuesta junto al roble"},
        roster: [{Archetypes.fighter(), :human}]
      )

    parent = self()

    model = %Test{
      script: [
        fn messages, params ->
          send(parent, {:dm_request, messages, params})
          narration("El muelle está en calma. ¿Qué haces?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    assert_receive {:dm_request, messages, params}
    assert Enum.any?(params.instructions, &(&1.content =~ "Eres el Dungeon Master"))
    wire = ModelMessages.project(messages)
    assert [%{"role" => "system", "content" => prompt} | _] = wire
    assert prompt =~ "Eres el Dungeon Master"
    assert prompt =~ "NUNCA decides tú el resultado"
    assert prompt =~ "La barquera espera una respuesta junto al roble"
    assert Enum.any?(wire, &(&1["content"] =~ "partida creada"))
    assert Enum.any?(wire, &(&1["content"] =~ "WORLD"))
  end

  test "the PC request carries its own identity and voice with the same event history" do
    pc = Archetypes.rogue()
    {:ok, game} = Games.create_game(title: "Voz propia enviada", roster: [{pc, :human}])
    history = History.from_events(Games.list_events(game.id))
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:pc_request, messages})
          narration("Vigilo la puerta.")
        end
      ]
    }

    agent = PCAgent.new(model, pc)
    server = start_supervised!({Server, agent: agent, agent_id: "voice-delivery-#{game.id}"})
    assert {:ok, _} = Dragonex.Agent.chat(server, "Responde como Vex.", message_history: history)
    assert_receive {:pc_request, messages}

    assert [%{"role" => "system", "content" => prompt} | _] =
             ModelMessages.project(messages)

    assert prompt ==
             PCAgent.system_prompt(pc) <> "\n\n" <> Dragonex.Narration.Contract.instruction()

    refute prompt =~ "Eres el Dungeon Master"

    assert Enum.any?(
             ModelMessages.project(messages),
             &(&1["content"] =~ "partida creada")
           )
  end

  test "compaction preserves its summary and still sends the current role first" do
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:compacted_request, messages})
          narration("La barca está amarrada.")
        end
      ]
    }

    agent =
      DM.new(model,
        summarizer: %Test{label: "El grupo encontró una barca bajo el roble."},
        compaction_threshold: 1,
        compaction_keep_recent: 1
      )

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "compact-delivery-#{System.unique_integer([:positive])}"}
      )

    history =
      Enum.map(
        [
          "El grupo busca el muelle",
          "Una barca está bajo el roble",
          "Última decisión: esperar en la orilla"
        ],
        &Message.new_request([%Message.Part.User{content: &1}])
      )

    assert {:ok, _} = Dragonex.Agent.chat(server, "Continúa.", message_history: history)
    assert_receive {:compacted_request, messages}
    wire = ModelMessages.project(messages)
    assert [%{"role" => "system", "content" => prompt} | _] = wire
    assert prompt == DM.system_prompt() <> "\n\n" <> Dragonex.Narration.Contract.instruction()

    assert Enum.any?(
             wire,
             &(&1["content"] =~ "Summary of earlier conversation" and
                 &1["content"] =~ "barca bajo el roble")
           )

    assert Enum.any?(wire, &(&1["content"] =~ "Última decisión"))
  end

  test "an existing current prompt is sent once across multiple tool steps and keeps its user content" do
    parent = self()

    observe = fn stage, response ->
      fn messages, _ ->
        send(parent, {:tool_request, stage, messages})
        response
      end
    end

    agent =
      DM.new(%Test{
        script: [
          observe.(:roll, tool_calls([call("roll_dice", %{"count" => 1, "sides" => 20})])),
          observe.(:final, narration("La tirada está resuelta."))
        ]
      })

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "steps-delivery-#{System.unique_integer([:positive])}"}
      )

    history = [
      Message.new_request(
        agent.instructions ++ [%Message.Part.User{content: "Busco el muelle del roble."}]
      )
    ]

    assert {:ok, _} =
             Dragonex.Agent.chat(server, "Haz una tirada.",
               message_history: history,
               deps: %{roller: fixed_roller(12)}
             )

    for stage <- [:roll, :final] do
      assert_receive {:tool_request, ^stage, messages}
      wire = ModelMessages.project(messages)

      assert Enum.count(
               wire,
               &(&1["role"] == "system" and
                   &1["content"] ==
                     DM.system_prompt() <> "\n\n" <> Dragonex.Narration.Contract.instruction())
             ) ==
               1

      assert Enum.any?(
               wire,
               &(&1["role"] == "user" and &1["content"] == "Busco el muelle del roble.")
             )

      if stage == :final, do: assert(Enum.any?(wire, &(&1["role"] == "tool")))
    end
  end
end
