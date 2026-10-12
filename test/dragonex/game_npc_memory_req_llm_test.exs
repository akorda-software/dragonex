defmodule Dragonex.GameNPCMemoryReqLLMTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  if Code.ensure_loaded?(ExAgent.Models.ReqLLM) do
    alias Dragonex.{Archetypes, Game, Games, Models}
    alias ExAgent.Models.Test

    defmodule Transport do
      def run(request), do: Application.fetch_env!(:dragonex, :npc_memory_http_fixture).(request)
    end

    @question "Le pregunto al zagal: «Cuando dijiste que lo viste de lejos, ¿te referías al abrigo? ¿Llegaste a ver de cerca la lana?» Espero aquí su respuesta."
    @statement "Me refería al abrigo; no pude ver de cerca su lana y no puedo confirmar quién dejó el hilo."
    @draft "El zagal aclara el referente sin registrar su testimonio."
    @answer "El zagal responde. —Al abrigo; no vi de cerca la lana y no puedo confirmar el dueño."

    test "stock v2 binds Decart/none and requests tools until memory commits, then permits validated output" do
      Dragonex.Test.Sandbox.start_shared!()
      owner = self()
      counter = start_supervised!({Agent, fn -> 0 end})
      previous = Application.get_env(:dragonex, :npc_memory_http_fixture)

      Application.put_env(:dragonex, :npc_memory_http_fixture, fn request ->
        index = Agent.get_and_update(counter, &{&1, &1 + 1})
        send(owner, {:memory_http, index, Jason.decode!(IO.iodata_to_binary(request.body))})
        call? = index == 1

        args =
          if call?,
            do: %{"speaker" => "El zagal", "statement" => @statement},
            else: %{"text" => if(index == 0, do: @draft, else: @answer)}

        message = %{
          "role" => "assistant",
          "content" => if(call?, do: nil, else: @draft),
          "tool_calls" => [
            %{
              "id" => "npc-memory-call-#{index}",
              "type" => "function",
              "function" => %{
                "name" => if(call?, do: "record_npc_statement", else: "final_result"),
                "arguments" => Jason.encode!(%{"arguments" => args})
              }
            }
          ]
        }

        body = %{
          "id" => "npc-memory-response-#{index}",
          "model" => "deepseek/deepseek-v4.1-flash",
          "choices" => [
            %{
              "index" => 0,
              "message" => message,
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}
        }

        {request,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         )}
      end)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:dragonex, :npc_memory_http_fixture, previous),
          else: Application.delete_env(:dragonex, :npc_memory_http_fixture)
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

      {:ok, game} =
        Games.create_game(
          title: "Native NPC memory",
          roster: [{Archetypes.wizard(name: "Mara"), :human}]
        )

      before = %{Games.load_world(game) | elapsed_seconds: 41_535, scene_refresh_pending: false}
      {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)

      {:ok, pid} =
        Game.ensure_started(game.id,
          model: model,
          scene_model: %Test{},
          turnmaster_model: %Test{}
        )

      on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
      # The real DM constructor supplies the settings compatible with `none`.
      # Select buffered beats for this JSON transport fixture without replacing
      # the DM's model/settings. Contract tests cover the publication boundary.
      :sys.replace_state(pid, &%{&1 | model: %Test{}})
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
      assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
      assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
      assert :ok == Game.pause(pid)
      world = Game.world(pid)
      assert Map.drop(world, [:facts]) == Map.drop(before, [:facts])

      assert world.facts == [
               "El zagal afirma: «#{@statement}» [Registrado a los 41535 s del reloj del mundo.]"
             ]

      assert Games.load_world(Games.get_game(game.id)) == world
      assert Agent.get(counter, & &1) == 3

      for index <- 0..2 do
        assert_receive {:memory_http, ^index, body}
        # Even after memory commits, public prose uses the typed output tool.
        assert body["tool_choice"] == "required"
        assert body["provider"]["only"] == ["decart"]
        assert body["provider"]["allow_fallbacks"] == false
        assert body["reasoning_effort"] == "none"

        output = Enum.find(body["tools"], &(&1["function"]["name"] == "final_result"))

        assert output["function"]["parameters"]["properties"]["arguments"]["properties"]["text"][
                 "type"
               ] == "string"

        if index == 1 do
          # Game starts a fresh run from shared public events and receipts.
          # The unpublished output is not imported into that shared history.
          refute inspect(body["messages"], limit: :infinity) =~ @draft
          assert inspect(body["messages"], limit: :infinity) =~ "record_npc_statement"
        end
      end

      events = Games.list_events(game.id)
      refute Enum.any?(events, &String.contains?(&1.payload["text"] || "", @draft))
      refute Enum.any?(events, &(&1.type == :dice))

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "dm" and &1.payload["complete"] == true)
             ) == 1

      assert [%{payload: %{"text" => @answer, "complete" => true}}] =
               Enum.filter(
                 events,
                 &(&1.type == :narration and &1.actor == "dm" and &1.payload["turn_id"] != nil)
               )
    end
  end
end
