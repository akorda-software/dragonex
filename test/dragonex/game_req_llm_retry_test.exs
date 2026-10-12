defmodule Dragonex.GameReqLLMRetryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Character, Game, Games, Models, World}

  @speech "Los proyectiles alcanzan al goblin."

  defmodule Transport do
    def run(request) do
      fun = Application.fetch_env!(:dragonex, :stock_http_retry_fixture)
      fun.(request)
    end
  end

  defp transport(failure, counter, owner) do
    fn request ->
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(owner, {:stock_http, index, Jason.decode!(IO.iodata_to_binary(request.body))})

      if index == 1 and failure == :http_503 do
        {request,
         Req.Response.new(
           status: 503,
           body: Jason.encode!(%{"error" => %{"message" => "fixture unavailable"}})
         )}
      else
        call? = index in [0, 1, 2]

        message =
          if call? do
            %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "stock-#{index}",
                  "type" => "function",
                  "function" => %{
                    "name" => "cast_spell",
                    "arguments" =>
                      Jason.encode!(%{
                        "arguments" => %{
                          "caster" => "Mara",
                          "spell" => if(index == 1, do: ["invalid type"], else: "magic missile"),
                          "target" => "Goblin"
                        }
                      })
                  }
                }
              ]
            }
          else
            %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "stock-final-#{index}",
                  "type" => "function",
                  "function" => %{
                    "name" => "final_result",
                    "arguments" => Jason.encode!(%{"arguments" => %{"text" => @speech}})
                  }
                }
              ]
            }
          end

        body = %{
          "id" => "stock-fixture",
          "model" => "buffered-fixture",
          "choices" => [
            %{
              "index" => 0,
              "message" => message,
              "finish_reason" => "tool_calls"
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
      end
    end
  end

  for failure <- [:http_503, :invalid_tool_arguments] do
    test "stock #{failure} after a committed spell retries without spending or rolling again" do
      Dragonex.Test.Sandbox.start_shared!()
      owner = self()
      counter = start_supervised!({Agent, fn -> 0 end})
      old = Application.get_env(:dragonex, :transient_backoffs)
      Application.put_env(:dragonex, :transient_backoffs, [1, 1, 1])

      on_exit(fn ->
        if old,
          do: Application.put_env(:dragonex, :transient_backoffs, old),
          else: Application.delete_env(:dragonex, :transient_backoffs)
      end)

      transport = transport(unquote(failure), counter, owner)

      # Req's adapter exercises the stock buffered HTTP path. The SSE contract
      # has a separate socket fixture in exAgent; this model is synthetic.
      metadata = %{"supported_parameters" => ["tools"]}
      model = Models.chat_model(:openrouter, "buffered-fixture", "synthetic", metadata)
      previous_transport = Application.get_env(:dragonex, :stock_http_retry_fixture)
      Application.put_env(:dragonex, :stock_http_retry_fixture, transport)

      on_exit(fn ->
        if previous_transport,
          do: Application.put_env(:dragonex, :stock_http_retry_fixture, previous_transport),
          else: Application.delete_env(:dragonex, :stock_http_retry_fixture)
      end)

      model = %{
        model
        | base_url: "https://fixture.invalid/v1",
          http_options: [adapter: Transport],
          provider_options: [
            openrouter_provider: Models.routing_for("deepseek/deepseek-v4.1-flash")
          ]
      }

      caster = Archetypes.wizard(name: "Mara")
      enemy = Character.new(name: "Goblin", side: "enemy", hp: 20, max_hp: 20)

      {:ok, game} =
        Games.create_game(
          title: "Stock HTTP retry",
          roster: [{caster, :ai}, {Archetypes.fighter(), :human}, {enemy, :ai}]
        )

      before = Games.load_world(game)
      {:ok, before} = World.begin_combat(["Mara", "Thane", "Goblin"]).(before)
      {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)

      {:ok, pid} =
        Game.ensure_started(game.id,
          model: %ExAgent.Models.Test{},
          roller: fn _ -> 1 end,
          scene_model: %ExAgent.Models.Test{},
          turnmaster_model: %ExAgent.Models.Test{}
        )

      on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
      assert :ok == ExAgent.Server.set_model(:sys.get_state(pid).pc_agents["Mara"], model)
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(pid)
      world = Game.world(pid)
      assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
      assert world.characters["Goblin"].hp == 14
      assert Games.load_world(Games.get_game(game.id)) == world
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
      assert Agent.get(counter, & &1) == 4

      assert Enum.count(
               Games.list_events(game.id),
               &(&1.type == :narration and &1.actor == "Mara" and
                   &1.payload["text"] == @speech and &1.payload["complete"])
             ) == 1

      refute Enum.any?(Games.list_events(game.id), fn event ->
               event.type == :system and
                 String.contains?(event.payload["note"] || "", "el turno falló")
             end)

      for index <- 0..3 do
        assert_receive {:stock_http, ^index, body}
        assert body["provider"]["only"] == ["decart"]
        assert body["provider"]["allow_fallbacks"] == false
        assert body["tool_choice"] == "required"
        output = Enum.find(body["tools"], &(&1["function"]["name"] == "final_result"))

        assert get_in(output, [
                 "function",
                 "parameters",
                 "properties",
                 "arguments",
                 "properties",
                 "text",
                 "type"
               ]) == "string"

        refute Map.has_key?(body, "reasoning_effort")
      end

      assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
