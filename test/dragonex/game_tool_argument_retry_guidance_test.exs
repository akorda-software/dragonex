defmodule Dragonex.GameToolArgumentRetryGuidanceTest.Model do
  @behaviour ExAgent.Model
  alias ExAgent.{Message, Message.Usage}
  defstruct [:counter, :owner, :tool, :arguments, :completion]

  @impl true
  def request(model, messages, _settings, _params) do
    n = Agent.get_and_update(model.counter, fn n -> {n, n + 1} end)
    send(model.owner, {:argument_retry_request, n, messages})

    if n == 0 do
      {:error,
       %ExAgent.RequestError{
         provider: :req_llm,
         reason: :invalid_tool_arguments,
         body: "provider-private-response"
       }}
    else
      parts =
        if n == 1,
          do: [Dragonex.Test.Harness.call(model.tool, model.arguments)],
          else: [model.completion]

      {:ok,
       Message.new_response(parts,
         usage: %Usage{input_tokens: 1, output_tokens: 1},
         model_name: "argument-retry"
       ), model}
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:error, error} -> [{:error, error}]
      {:ok, response, updated} -> [Dragonex.Test.Harness.stream_response(response, updated)]
    end
  end

  @impl true
  def model_name(_), do: "argument-retry"
  @impl true
  def system(_), do: "argument-retry"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
end

defmodule Dragonex.GameToolArgumentRetryGuidanceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.GameToolArgumentRetryGuidanceTest.Model
  alias Dragonex.Test.ModelMessages
  alias ExAgent.{Models.Test, Server}
  @prefix "REINTENTO DE HERRAMIENTAS:"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    previous = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [10, 10, 10])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dragonex, :transient_backoffs, previous),
        else: Application.delete_env(:dragonex, :transient_backoffs)
    end)

    {:ok, game} =
      Games.create_game(
        title: "Feedback tras argumentos inválidos",
        roster: [{Archetypes.fighter(), :human}]
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)

    counter =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> 0 end}, id: {:retry_counter, game.id})
      )

    %{game: game, world: world, counter: counter}
  end

  defp guides(messages) do
    ModelMessages.project(messages)
    |> Enum.filter(&(&1["role"] == "system" and String.starts_with?(&1["content"], @prefix)))
  end

  for role <- [:actor, :turnmaster] do
    test "#{role} passes only the rejected-arguments cause into the next request and preserves effects",
         %{game: game, world: before, counter: counter} do
      model = %Model{
        counter: counter,
        owner: self(),
        tool: if(unquote(role) == :actor, do: "grant_item", else: "give_turn_to"),
        completion:
          if(unquote(role) == :actor,
            do:
              Dragonex.Test.Harness.call("final_result", %{"text" => "El farol queda registrado."}),
            else: %ExAgent.Message.Part.Text{content: "Listo."}
          ),
        arguments:
          if(unquote(role) == :actor,
            do: %{"who" => "Thane", "item" => "farol", "quantity" => 1},
            else: %{"participant" => "Thane"}
          )
      }

      opts =
        if unquote(role) == :actor,
          do: [model: model, turnmaster_model: %Test{}],
          else: [
            model: %Dragonex.Test.Narrator{text: "La salida está despejada."},
            turnmaster_model: model
          ]

      pid = Dragonex.Test.GameFixture.start!({Game, {game.id, opts}})
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
      assert :ok == Game.pause(pid)
      assert_receive {:argument_retry_request, 0, first}
      assert_receive {:argument_retry_request, 1, retried}
      assert guides(first) == []
      assert [%{"content" => cue}] = guides(retried)
      assert cue =~ "JSON Schema"
      refute inspect(retried) =~ "provider-private-response"
      state = :sys.get_state(pid)
      server = if unquote(role) == :actor, do: state.dm, else: state.turnmaster
      assert guides(Server.history(server)) == []
      world = Game.world(pid)
      assert world.elapsed_seconds == before.elapsed_seconds
      assert Games.load_world(Games.get_game(game.id)) == world

      if unquote(role) == :actor do
        assert Enum.find(world.characters["Thane"].inventory, &(&1.name == "farol")).qty == 1
      else
        assert world == before
      end

      events = Games.list_events(game.id)
      assert Enum.count(events, &(&1.type == :turn)) == 1
      refute Enum.any?(events, &(&1.type == :dice))
      refute inspect(events) =~ @prefix
      refute Enum.any?(events, &String.contains?(&1.payload["note"] || "", "el turno falló"))
    end
  end
end
