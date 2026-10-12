defmodule Dragonex.HistoryReqLLMTest do
  use ExUnit.Case, async: false

  if Code.ensure_loaded?(ExAgent.Models.ReqLLM) do
    alias Dragonex.{AgentInstructions, History, Models}
    alias Dragonex.Games.GameEvent
    alias ExAgent.{Message, Model, ModelRequestParameters, ModelSettings, Tool}

    defmodule Transport do
      def run(request), do: Application.fetch_env!(:dragonex, :history_http_fixture).(request)
    end

    test "stored narrative is host memory, while the current tool run retains native none continuations" do
      owner = self()
      counter = start_supervised!({Agent, fn -> 0 end})
      previous = Application.get_env(:dragonex, :history_http_fixture)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:dragonex, :history_http_fixture, previous),
          else: Application.delete_env(:dragonex, :history_http_fixture)
      end)

      Application.put_env(:dragonex, :history_http_fixture, fn request ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        send(owner, {:history_http, n, Jason.decode!(IO.iodata_to_binary(request.body))})

        message =
          if n == 0 do
            %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "memory-call",
                  "type" => "function",
                  "function" => %{
                    "name" => "remember",
                    "arguments" => Jason.encode!(%{"arguments" => %{"value" => 7}})
                  }
                }
              ]
            }
          else
            %{"role" => "assistant", "content" => "Recuerdo la propuesta de Lyra."}
          end

        body = %{
          "id" => "history-fixture",
          "model" => "deepseek/deepseek-v4.1-flash",
          "choices" => [
            %{
              "index" => 0,
              "message" => message,
              "finish_reason" => if(n == 0, do: "tool_calls", else: "stop")
            }
          ],
          "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1}
        }

        {request,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         )}
      end)

      metadata = %{
        "supported_parameters" => ["tools", "reasoning_effort"],
        "reasoning" => %{"mandatory" => false}
      }

      model =
        Models.chat_model(:openrouter, "deepseek/deepseek-v4.1-flash", "synthetic", metadata)

      model = %{
        model
        | base_url: "https://fixture.invalid/v1",
          http_options: [adapter: Transport]
      }

      tool =
        Tool.new(
          name: "remember",
          parameters_json_schema: %{
            type: "object",
            properties: %{value: %{type: "integer"}},
            required: ["value"],
            additionalProperties: false
          },
          call: fn _ctx, args ->
            send(owner, {:remembered, args})
            "recordado"
          end
        )

      events = [
        %GameEvent{
          type: :narration,
          actor: "dm",
          visible_to: "all",
          seq: 1,
          payload: %{"text" => "La noria gira."}
        },
        %GameEvent{
          type: :narration,
          actor: "Lyra",
          visible_to: "all",
          seq: 2,
          payload: %{"text" => "¿Buscamos testigos?"}
        },
        %GameEvent{
          type: :narration,
          actor: "dm",
          visible_to: "dm",
          seq: 3,
          payload: %{"text" => "Secreto privado."}
        }
      ]

      params = %ModelRequestParameters{function_tools: [tool]}
      settings = %ModelSettings{max_tokens: 128}

      # Causal control: the old synthetic assistant history is rejected before
      # HTTP. Importing textual records must not loosen the library's guard.
      assert {:error, %{reason: :continuation_routing_mismatch}} =
               Model.request(model, History.from_events(events), settings, params)

      assert Agent.get(counter, & &1) == 0

      imported = History.import_events(events, "Lyra")
      assert Enum.all?(imported, &match?(%Message.Request{}, &1))

      agent =
        ExAgent.new(
          model: model,
          instructions: "Hablas como Vex.",
          tools: [tool],
          model_settings: [max_tokens: 128],
          capabilities: Dragonex.Agent.capabilities([AgentInstructions])
        )

      {:ok, server} = ExAgent.Server.start_link(agent: agent)

      try do
        assert {:ok, result} =
                 ExAgent.Server.chat(server, "Responde a Mara.", message_history: imported)

        assert result.output == "Recuerdo la propuesta de Lyra."
        assert result.request_count == 2
        assert_receive {:remembered, %{"value" => 7}}
        refute_receive {:remembered, _}, 0
        assert Agent.get(counter, & &1) == 2

        for n <- 0..1 do
          assert_receive {:history_http, ^n, body}
          assert body["provider"]["only"] == ["decart"]
          assert body["reasoning_effort"] == "none"
          refute Map.has_key?(body, "temperature")

          narration =
            Enum.filter(
              body["messages"],
              &String.contains?(&1["content"] || "", "CRÓNICA REGISTRADA")
            )

          assert length(narration) == 2
          assert Enum.all?(narration, &(&1["role"] == "user"))

          assert Enum.any?(
                   narration,
                   &String.contains?(&1["content"], "[Lyra]: ¿Buscamos testigos?")
                 )

          refute Jason.encode!(body["messages"]) =~ "Secreto privado"
        end

        assert Message.from_json(Message.to_json(result.messages)) == {:ok, result.messages}
      after
        GenServer.stop(server)
      end
    end
  end
end
