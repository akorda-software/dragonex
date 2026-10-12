defmodule Dragonex.NarrationReqLLMTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  if Code.ensure_loaded?(ExAgent.Models.ReqLLM) do
    alias Dragonex.{Archetypes, Events, Games, History, Models, Narration}
    alias Dragonex.Narration.Contract
    alias Dragonex.Test.ModelMessages
    alias ExAgent.Message.Response

    @private "I need to consider the tool results and decide what to say next."
    @public "La campanilla de cobre está sobre la mesa."

    defmodule Transport do
      def run(request), do: Application.fetch_env!(:dragonex, :narration_http_fixture).(request)
    end

    test "the stock adapter retries privately while preserving native content, routing and the output envelope" do
      Dragonex.Test.Sandbox.start_shared!()

      {:ok, game} =
        Games.create_game(
          title: "Contrato con transporte nativo",
          roster: [{Archetypes.fighter(), :human}]
        )

      baseline = Games.list_events(game.id)
      owner = self()
      counter = start_supervised!({Agent, fn -> 0 end})
      previous = Application.get_env(:dragonex, :narration_http_fixture)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:dragonex, :narration_http_fixture, previous),
          else: Application.delete_env(:dragonex, :narration_http_fixture)
      end)

      Application.put_env(:dragonex, :narration_http_fixture, fn request ->
        step = Agent.get_and_update(counter, &{&1, &1 + 1})
        send(owner, {:narration_http, step, Jason.decode!(IO.iodata_to_binary(request.body))})

        message =
          if step == 0 do
            %{"role" => "assistant", "content" => @private}
          else
            %{
              "role" => "assistant",
              "content" => @private,
              "tool_calls" => [
                %{
                  "id" => "native-final",
                  "type" => "function",
                  "function" => %{
                    "name" => "final_result",
                    "arguments" => Jason.encode!(%{"arguments" => %{"text" => @public}})
                  }
                }
              ]
            }
          end

        body = %{
          "id" => "narration-fixture",
          "model" => "deepseek/deepseek-v4.1-flash",
          "choices" => [
            %{
              "index" => 0,
              "message" => message,
              "finish_reason" => if(step == 0, do: "stop", else: "tool_calls")
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

      agent =
        ExAgent.new(
          model: model,
          output: Narration,
          model_settings: [max_tokens: 512],
          capabilities: Dragonex.Agent.capabilities([Contract, Events])
        )

      deps = %{
        beat: %{game_id: game.id, actor: "dm", turn_id: "native-narration", pc_names: ["Thane"]}
      }

      assert {:ok, %{output: %Narration{text: @public}} = result} =
               ExAgent.run(agent, "Responde mediante final_result.", deps: deps)

      assert Agent.get(counter, & &1) == 2
      assert Games.list_events(game.id) == baseline

      for step <- 0..1 do
        assert_receive {:narration_http, ^step, request}
        assert request["provider"]["only"] == ["decart"]
        assert request["provider"]["allow_fallbacks"] == false
        assert request["reasoning_effort"] == "none"
        refute Map.has_key?(request, "temperature")
        output = Enum.find(request["tools"], &(&1["function"]["name"] == "final_result"))

        assert output["function"]["parameters"]["properties"]["arguments"]["properties"]["text"][
                 "type"
               ] == "string"

        if step == 1 do
          assistant = Enum.find(request["messages"], &(&1["role"] == "assistant"))
          assert assistant["content"] == @private
        end
      end

      assert Enum.count(
               result.new_messages,
               &(match?(%Response{}, &1) and Response.text(&1) == @private)
             ) == 2

      assert {:ok, @public} = Contract.publish_result(result, deps)
      assert Games.completed_narration(game.id, "dm", "native-narration") == @public

      refute inspect(History.import_events(Games.list_events(game.id)) |> ModelMessages.project()) =~
               @private

      assert [%{payload: %{"text" => @public}}] =
               Enum.filter(
                 Games.list_events(game.id),
                 &(&1.payload["turn_id"] == "native-narration")
               )
    end
  end
end
