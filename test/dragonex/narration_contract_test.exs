defmodule Dragonex.NarrationContractTest.StreamModel do
  @behaviour ExAgent.Model
  defstruct [:inner]

  @impl true
  def request(model, messages, settings, params) do
    with {:ok, response, inner} <-
           ExAgent.Models.Test.request(model.inner, messages, settings, params),
         do: {:ok, response, %{model | inner: inner}}
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:ok, response, updated} ->
        [
          {:text_delta, ExAgent.Message.Response.text(response)},
          Dragonex.Test.Harness.stream_response(response, updated)
        ]

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  @impl true
  def model_name(_), do: "narration-boundary-stream"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
end

defmodule Dragonex.NarrationContractTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Archetypes, Events, Games, History, Narration, Text, World}
  alias Dragonex.Game.{NPCMemoryResolution, RunLifecycle, WaitResolution}
  alias Dragonex.Narration.Contract
  alias Dragonex.Test.ModelMessages
  alias ExAgent.{Message, Models.Test, Server, Session, Tool}
  alias ExAgent.Message.{Part, Response}
  alias ExAgent.Session.SharedState

  @public "La campanilla de cobre está sobre la mesa."
  @private "I need to consider the tool results and decide what to say next."

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(
        title: "Salida pública estructurada",
        roster: [{Archetypes.fighter(), :human}]
      )

    world = Games.load_world(game)

    beat = %{
      game_id: game.id,
      actor: "dm",
      turn_id: "structured",
      pc_names: ["Thane"],
      character_names: ["Thane"]
    }

    %{game: game, world: world, deps: %{beat: beat}, baseline: Games.list_events(game.id)}
  end

  defp final(text \\ @public, id \\ "public-result") do
    %Part.ToolCall{tool_name: "final_result", args: %{"text" => text}, tool_call_id: id}
  end

  defp response(parts, finish \\ :tool_calls),
    do: Message.new_response(parts, finish_reason: finish)

  defp agent(script, tools) do
    ExAgent.new(
      model: %Test{script: script},
      output: Narration,
      tools: tools,
      capabilities:
        Dragonex.Agent.capabilities([
          RunLifecycle,
          WaitResolution,
          NPCMemoryResolution,
          Contract,
          Events
        ])
    )
  end

  defp run(script, deps, tools \\ []),
    do: ExAgent.run(agent(script, tools), "Resuelve y narra.", deps: deps)

  defp speech(game),
    do: Enum.filter(Games.list_events(game.id), &(&1.payload["turn_id"] == "structured"))

  defp resolve_tool(counter) do
    Tool.new(
      name: "resolve",
      parameters_json_schema: %{type: "object", properties: %{}, required: []},
      call: fn _ctx, _args ->
        Agent.update(counter, &(&1 + 1))
        "Resultado aplicado una vez."
      end
    )
  end

  defp shared(deps, world) do
    session =
      start_supervised!(
        {Session,
         shared_state: world,
         session_id: "narration-#{System.unique_integer([:positive])}",
         participants: [ExAgent.Session.Participant.new(id: "dm", kind: :agent)],
         policy: :round_robin},
        id: make_ref()
      )

    Map.put(deps, :state, SharedState.new(session, "dm"))
  end

  defp completed_result(text \\ @public) do
    %{
      output: %Narration{text: text},
      new_messages: [
        response([final(text)]),
        Message.new_request([
          %Part.ToolReturn{
            tool_name: "final_result",
            tool_call_id: "public-result",
            content: "ok"
          }
        ])
      ]
    }
  end

  test "public output schema rejects missing, blank, invalid and oversized prose" do
    schema = ExAgent.OutputSchema.json_schema(Narration)
    assert schema.required == ["text"]
    assert schema.properties["text"].type == "string"
    assert schema.properties["text"].maxLength == 8000

    for attrs <- [
          %{},
          %{"text" => nil},
          %{"text" => "  "},
          %{"text" => 17},
          %{"text" => <<255>>},
          %{"text" => String.duplicate("ñ", 8001)}
        ] do
      assert {:error, _} = ExAgent.OutputSchema.validate(Narration, attrs)
    end

    assert {:ok, %Narration{text: "¿Qué ves?"}} =
             ExAgent.OutputSchema.validate(Narration, %{"text" => " ¿Qué ves? "})
  end

  test "private responses retain native content, parts and termination flags without publishing",
       %{
         deps: deps,
         game: game,
         baseline: baseline
       } do
    old = response([%Part.Text{content: "Historia previa."}], :stop)
    call = %Part.ToolCall{tool_name: "resolve", args: %{}, tool_call_id: "native-id"}
    thinking = %Part.Thinking{content: "Native private data", signature: "native-signature"}

    for finish <- [:tool_calls, :length, :content_filter, :unknown, :incomplete, :error] do
      current = response([%Part.Text{content: @private}, thinking, call], finish)
      state = %{agent: %{output_type: Narration}, deps: deps, messages: [old, current]}
      changed = Contract.after_model_request(Contract, state)
      assert changed == state
      assert Events.after_model_request(Events, changed) == state
      assert Games.list_events(game.id) == baseline
    end

    generic = %{agent: %{output_type: :text}, deps: deps, messages: [old]}
    assert Contract.after_model_request(Contract, generic) == generic
  end

  test "typed closure disables raw streaming and cannot be converted back to free-text completion",
       %{deps: deps} do
    state = %{
      agent: %{output_type: Narration},
      deps: Map.put(deps, :on_text_delta, fn chunk -> send(self(), {:raw_preview, chunk}) end),
      params: %{allow_text_output: true}
    }

    changed = Contract.before_model_request(Contract, state)
    refute changed.params.allow_text_output
    changed.deps.on_text_delta.(@private)
    refute_received {:raw_preview, _}
    generic = put_in(state.agent.output_type, :text)
    assert Contract.before_model_request(Contract, generic) == generic
  end

  test "actual rules tools finish before one validated public speech; deliberation is not public history",
       %{game: game, deps: deps, world: world, baseline: baseline} do
    counter = start_supervised!({Agent, fn -> 0 end})
    call = %Part.ToolCall{tool_name: "resolve", args: %{}, tool_call_id: "resolve-once"}

    {:ok, result} =
      run(
        [
          response([%Part.Text{content: @private}, call]),
          response([%Part.Text{content: @private}, final()])
        ],
        deps,
        [resolve_tool(counter)]
      )

    assert Agent.get(counter, & &1) == 1
    assert Games.list_events(game.id) == baseline
    assert {:ok, @public} = Contract.publish_result(result, deps)
    assert [%{payload: %{"text" => @public, "complete" => true}}] = speech(game)
    assert Games.completed_narration(game.id, "dm", "structured") == @public

    refute inspect(History.import_events(Games.list_events(game.id)) |> ModelMessages.project()) =~
             @private

    assert Games.load_world(Games.get_game(game.id)) == world

    calls =
      for %Response{} = msg <- result.new_messages, call <- Response.tool_calls(msg), do: call

    assert Enum.map(calls, &{&1.tool_name, &1.tool_call_id, &1.args}) == [
             {"resolve", "resolve-once", %{}},
             {"final_result", "public-result", %{"text" => @public}}
           ]
  end

  test "free prose cannot complete or leak into the timeline even when the output retry is exhausted",
       %{game: game, deps: deps, baseline: baseline} do
    assert {:error, _} = run([@private, @private], deps)
    assert Games.list_events(game.id) == baseline
    assert Games.completed_narration(game.id, "dm", "structured") == nil
  end

  test "an output call beside an unexecuted rule or another output never confirms a beat", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    counter = start_supervised!({Agent, fn -> 0 end})

    for sibling <- [
          %Part.ToolCall{tool_name: "resolve", args: %{}, tool_call_id: "omitted-rule"},
          final("Otra respuesta.", "other-result")
        ] do
      {:ok, result} = run([response([final(), sibling])], deps, [resolve_tool(counter)])

      assert {:error, {:narration_contract, :mixed_completion}} =
               Contract.publish_result(result, deps)

      assert Agent.get(counter, & &1) == 0
      assert Games.list_events(game.id) == baseline
      assert Games.completed_narration(game.id, "dm", "structured") == nil
    end
  end

  test "invalid structured prose retries through the real loop without publishing a false completion",
       %{game: game, deps: deps, baseline: baseline} do
    {:ok, result} = run([response([final("")]), response([final()])], deps)
    assert result.run_step == 2
    assert Games.list_events(game.id) == baseline
    assert {:ok, @public} = Contract.publish_result(result, deps)
    assert length(speech(game)) == 1
  end

  test "terminal flags, unpaired output and a forged bare schema cannot create a receipt", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    for finish <- [:length, :content_filter, :unknown, :incomplete, :error] do
      result = completed_result()
      [last, receipt] = result.new_messages
      result = %{result | new_messages: [%{last | finish_reason: finish}, receipt]}

      assert {:error, {:narration_contract, :invalid_completion}} =
               Contract.publish_result(result, deps)
    end

    for result <- [
          %{output: %Narration{text: @public}},
          %{completed_result() | new_messages: []},
          %{completed_result() | output: %Narration{text: "Otra cosa."}},
          %{completed_result() | new_messages: [response([final()])]}
        ] do
      assert {:error, {:narration_contract, :invalid_completion}} =
               Contract.publish_result(result, deps)
    end

    assert Games.list_events(game.id) == baseline
  end

  test "structured output cannot bypass a pending timed wait, including a zero-second interruption",
       %{game: game, world: world, deps: deps, baseline: baseline} do
    request = %{
      seconds: 60,
      clock_before: world.elapsed_seconds,
      source_turn_id: "human-wait",
      actor: "Thane",
      declaration: "Espero un minuto."
    }

    pending = deps |> put_in([:beat, :wait_resolution], request) |> shared(world)
    {:ok, result} = run([response([final()])], pending)

    assert {:error, {:narration_contract, :wait_unresolved}} =
             Contract.publish_result(result, pending)

    assert SharedState.read(pending.state) == world
    assert Games.list_events(game.id) == baseline
    {:ok, interrupted} = World.resolve_wait("human-wait", 60, 0).(world)
    resolved = deps |> put_in([:beat, :wait_resolution], request) |> shared(interrupted)
    assert {:ok, @public} = Contract.publish_result(result, resolved)
    assert SharedState.read(resolved.state) == interrupted
    assert interrupted.elapsed_seconds == world.elapsed_seconds
    assert length(speech(game)) == 1
  end

  test "NPC clarification needs a receipt for this source and turn, not merely an existing fact",
       %{game: game, world: world, deps: deps, baseline: baseline} do
    pending =
      deps
      |> put_in([:beat, :npc_memory_resolution], %{speaker: "Berta"})
      |> shared(%{world | facts: ["Berta dice: «No pude verlo». "]})

    {:ok, result} = run([response([final()])], pending)

    assert {:error, {:narration_contract, :npc_memory_unresolved}} =
             Contract.publish_result(result, pending)

    assert Games.list_events(game.id) == baseline

    receipt = %{
      "actor" => "dm",
      "turn_id" => "structured",
      "phase" => "exploration",
      "mini_turn" => false,
      "enemies_before" => [],
      "tools" => [
        %{
          "name" => "record_npc_statement",
          "args" => %{"speaker" => "Berta"},
          "values" => ["Testimonio registrado."]
        }
      ]
    }

    recorded = %{world | actor_checkpoint: receipt}

    resolved =
      deps |> put_in([:beat, :npc_memory_resolution], %{speaker: "Berta"}) |> shared(recorded)

    assert {:ok, @public} = Contract.publish_result(result, resolved)
    assert SharedState.read(resolved.state) == recorded
    assert length(speech(game)) == 1
  end

  test "a manual resolver still publishes the durable player's source as an intent", %{
    game: game,
    deps: deps
  } do
    source = "Le entrego la campanilla a Berta y digo: «Aquí tienes»."
    deps = deps |> put_in([:beat, :actor], "Thane") |> put_in([:beat, :human_declaration], source)

    {:ok, result} =
      run(
        [response([%Part.Text{content: "Sonrío y prometo volver."}, final("Acción resuelta.")])],
        deps
      )

    assert speech(game) == []
    assert {:ok, ^source} = Contract.publish_result(result, deps)

    assert [
             %{
               actor: "Thane",
               payload: %{"text" => ^source, "kind" => "human_declaration", "complete" => true}
             }
           ] = speech(game)

    assert [%{"role" => "user", "content" => content}] =
             History.from_events(speech(game)) |> ModelMessages.project()

    assert content =~ "Thane declara" and content =~ source
    refute content =~ "Sonrío"
  end

  test "empty sanitized speech or a cancelled owner cannot return successful publication", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    forbidden = "Thane entra en el almacén."
    assert Text.scrub(forbidden, "dm", pc_names: ["Thane"], character_names: ["Thane"]) == ""

    assert {:error, {:narration_contract, :empty_speech}} =
             Contract.publish_result(completed_result(forbidden), deps)

    owner = spawn(fn -> :ok end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    assert {:error, {:narration_contract, :cancelled}} =
             Contract.publish_result(completed_result(), Map.put(deps, :game_owner, owner))

    assert Games.list_events(game.id) == baseline
    assert Games.completed_narration(game.id, "dm", "structured") == nil
  end

  test "a previously successful output outside this run is not a current completion", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    result = %{
      completed_result()
      | new_messages: [Message.new_request([%Part.User{content: "Nuevo turno."}])]
    }

    result = Map.put(result, :messages, completed_result().new_messages ++ result.new_messages)

    assert {:error, {:narration_contract, :invalid_completion}} =
             Contract.publish_result(result, deps)

    assert Games.list_events(game.id) == baseline
  end

  test "the actual Server stream keeps raw deltas private, with a working unguarded control", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    observer = self()
    deps = Map.put(deps, :on_text_delta, fn chunk -> send(observer, {:preview, chunk}) end)

    model = %Dragonex.NarrationContractTest.StreamModel{
      inner: %Test{script: [response([%Part.Text{content: @private}, final()])]}
    }

    agent = %{agent([], []) | model: model}

    server =
      start_supervised!(
        {Server,
         agent: agent, agent_id: "structured-stream-#{System.unique_integer([:positive])}"},
        id: make_ref()
      )

    assert {:ok, %{output: %Narration{text: @public}} = result} =
             Dragonex.Agent.chat(server, "Narra.",
               deps: deps,
               stream_text: true,
               message_history: []
             )

    assert Games.list_events(game.id) == baseline
    refute_received {:preview, _}
    assert {:ok, @public} = Contract.publish_result(result, deps)

    # Prove the same callback does receive real raw deltas without the
    # boundary; silence alone is not a stream test.
    unguarded =
      ExAgent.new(
        model: %Dragonex.NarrationContractTest.StreamModel{inner: %Test{script: [@private]}}
      )

    control =
      start_supervised!(
        {Server,
         agent: unguarded, agent_id: "unguarded-stream-#{System.unique_integer([:positive])}"},
        id: make_ref()
      )

    assert {:ok, _} = Dragonex.Agent.chat(control, "Narra.", deps: deps, stream_text: true)
    assert_receive {:preview, @private}
  end

  test "publication rejects missing beat context and failed native output returns", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    for context <- [
          nil,
          %{},
          %{beat: %{game_id: game.id}},
          put_in(deps.beat.turn_id, ""),
          put_in(deps.beat.actor, "")
        ] do
      assert {:error, {:narration_contract, :invalid_context}} =
               Contract.publish_result(completed_result(), context)
    end

    [response, receipt] = completed_result().new_messages
    [part] = receipt.parts

    for failed <- [
          %{part | tool_call_id: "wrong-id"},
          %{part | content: "not executed"},
          Map.put(part, :status, :not_executed)
        ] do
      result = %{completed_result() | new_messages: [response, %{receipt | parts: [failed]}]}

      assert {:error, {:narration_contract, :invalid_completion}} =
               Contract.publish_result(result, deps)
    end

    assert Games.list_events(game.id) == baseline
  end
end
