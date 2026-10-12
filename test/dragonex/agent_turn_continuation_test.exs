defmodule Dragonex.AgentTurnContinuationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{AgentInstructions, Archetypes, DM, Games, History}
  alias Dragonex.Test.ModelMessages
  alias ExAgent.{Message, Models.Test, Server}
  alias ExAgent.Message.Part

  @prefix "CONTINUACIÓN DEL TURNO:"

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(title: "Prosa después de tools", roster: [{Archetypes.fighter(), :human}])

    beat = %{
      game_id: game.id,
      actor: "dm",
      turn_id: "continuation-one",
      phase: :exploration,
      round: 1
    }

    %{game: game, beat: beat}
  end

  defp guides(messages) do
    messages
    |> ModelMessages.project()
    |> Enum.filter(&(&1["role"] == "system" and String.starts_with?(&1["content"], @prefix)))
  end

  defp project(beat, messages \\ []) do
    state = %{
      agent: %{instructions: [%Part.System{content: "Reglas actuales del DM."}]},
      messages: messages,
      request_messages: nil,
      deps: %{beat: beat}
    }

    {state, AgentInstructions.before_model_request(AgentInstructions, state)}
  end

  defp publish(game, beat, opts \\ []) do
    payload = %{
      text: Keyword.get(opts, :text, "La puerta está entreabierta."),
      turn_id: Keyword.get(opts, :turn_id, beat.turn_id),
      complete: Keyword.get(opts, :complete, false)
    }

    Games.append_event(
      game.id,
      :narration,
      Keyword.get(opts, :actor, beat.actor),
      Keyword.get(opts, :visible_to, "all"),
      payload
    )
  end

  test "actual tool continuations receive one cue only after speech was published, retaining every segment",
       %{game: game, beat: beat} do
    owner = self()

    texts = [
      "La puerta está entreabierta.",
      "Hay una muesca en la cerradura.",
      "El interior sigue en silencio."
    ]

    observe = fn stage, response ->
      fn messages, _ ->
        send(owner, {:continuation_request, stage, messages})
        response
      end
    end

    response = fn text ->
      Message.new_response([
        call("narrate", %{"text" => text}),
        call("roll_dice", %{"count" => 1, "sides" => 20})
      ])
    end

    agent =
      DM.new(%Test{
        script: [
          observe.(0, response.(Enum.at(texts, 0))),
          observe.(1, response.(Enum.at(texts, 1))),
          observe.(2, narration(Enum.at(texts, 2)))
        ]
      })

    server = start_supervised!({Server, agent: agent, agent_id: "continuation-#{game.id}"})
    before = Games.load_world(game)

    assert {:ok, %{output: %Dragonex.Narration{text: "El interior sigue en silencio."}} = result} =
             Dragonex.Agent.chat(server, "Observa la puerta.",
               deps: %{beat: beat, roller: fixed_roller(12)}
             )

    assert {:ok, "El interior sigue en silencio."} =
             Dragonex.Narration.Contract.publish_result(result, %{beat: beat})

    for stage <- 0..2 do
      assert_receive {:continuation_request, ^stage, messages}

      if stage == 0 do
        assert guides(messages) == []
      else
        assert [%{"content" => cue}] = guides(messages)
        assert cue =~ "ya se publicó en la mesa"
        assert cue =~ "No la vuelvas a narrar ni la reformules"
        assert cue =~ "conserva los datos reales de las herramientas"
        assert Enum.any?(ModelMessages.project(messages), &(&1["role"] == "tool"))
      end
    end

    events = Games.list_events(game.id)

    speech =
      Enum.filter(events, &(&1.type == :narration and &1.payload["turn_id"] == beat.turn_id))

    assert Enum.map(speech, & &1.payload["text"]) == texts
    assert Enum.map(speech, & &1.payload["complete"]) == [false, false, true]
    assert Games.completed_narration(game.id, "dm", beat.turn_id) == List.last(texts)
    assert Games.load_world(Games.get_game(game.id)) == before
    history = inspect(History.from_events(events), limit: :infinity)
    for text <- texts, do: assert(history =~ text)
    refute history =~ @prefix
  end

  test "only public intermediate speech from the same game, actor and turn enables the cue", %{
    game: game,
    beat: beat
  } do
    {:ok, other} = Games.create_game(title: "Otra mesa", roster: [{Archetypes.fighter(), :human}])

    for {target, opts} <- [
          {other, []},
          {game, [actor: "Thane"]},
          {game, [turn_id: "older"]},
          {game, [visible_to: "dm"]},
          {game, [complete: true]},
          {game, [complete: "false"]},
          {game, [text: ""]},
          {game, [text: 12]}
        ] do
      assert {:ok, _} = publish(target, beat, opts)
      {_, projected} = project(beat)
      assert guides(projected.request_messages) == []
    end

    assert {:ok, _} = publish(game, beat)
    {_, projected} = project(beat)
    assert length(guides(projected.request_messages)) == 1
  end

  test "the cue changes only request projection, remains unique and is absent without a beat", %{
    game: game,
    beat: beat
  } do
    assert {:ok, _} = publish(game, beat)
    history = [Message.new_request([%Part.User{content: "Conserva esta declaración."}])]
    {original, projected} = project(beat, history)
    assert projected.messages == history and projected.deps == original.deps
    assert projected.agent == original.agent
    repeated = AgentInstructions.before_model_request(AgentInstructions, projected)
    assert length(guides(repeated.request_messages)) == 1

    assert Enum.any?(
             ModelMessages.project(repeated.request_messages),
             &(&1["content"] == "Conserva esta declaración.")
           )

    standalone = %{original | deps: %{}}

    assert guides(
             AgentInstructions.before_model_request(AgentInstructions, standalone).request_messages
           ) == []
  end
end
