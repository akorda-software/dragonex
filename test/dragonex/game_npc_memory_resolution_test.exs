defmodule Dragonex.GameNPCMemoryResolutionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games}
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  defmodule StreamModel do
    @behaviour ExAgent.Model
    defstruct [:counter, :script]

    def request(model, messages, settings, params) do
      index = Agent.get_and_update(model.counter, &{&1, &1 + 1})
      reply = Enum.at(model.script, index, "(sin respuesta)")

      {:ok, response, _} =
        ExAgent.Models.Test.request(
          %ExAgent.Models.Test{script: [reply]},
          messages,
          settings,
          params
        )

      {:ok, response, model}
    end

    def request_stream(model, messages, settings, params) do
      {:ok, response, _} = request(model, messages, settings, params)
      text = ExAgent.Message.Response.text(response)

      Stream.concat([
        if(text == "", do: [], else: [{:text_delta, text}]),
        [Dragonex.Test.Harness.stream_response(response, model)]
      ])
    end

    def model_name(_), do: "memory-stream-fixture"
    def system(_), do: "memory-stream-fixture"
    def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
  end

  @question "Le pregunto al zagal de las cabras: «Cuando dijiste que lo viste de lejos, ¿te referías al forastero, a su abrigo o al hilo? ¿Llegaste a ver de cerca la lana de su abrigo?» Espero aquí su respuesta."
  @original "El zagal de las cabras afirma: «Ese hilo se parece al abrigo, pero lo vi de lejos y no puedo jurar que sea la misma lana.» [Registrado a los 41535 s del reloj del mundo.]"
  @statement "Me refería al forastero; no vi de cerca la lana del abrigo y su dueño sigue sin confirmar."
  @recorded "El zagal de las cabras afirma: «#{@statement}» [Registrado a los 41535 s del reloj del mundo.]"
  @answer "El zagal responde. —Al forastero; no vi de cerca la lana del abrigo."
  @unrecorded "El zagal aclara el referente, pero no lo registra."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(script, facts \\ [@original], opts \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "Una aclaración conserva su fuente",
        scene: "El cruce del molino.",
        roster: [{Archetypes.wizard(name: "Mara"), :human}]
      )

    before = %{
      Games.load_world(game)
      | elapsed_seconds: 41_535,
        facts: facts,
        scene_refresh_pending: false
    }

    {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
    owner = self()

    unexpected = fn _, _ ->
      send(owner, :unexpected_memory_auxiliary)
      "No corresponde."
    end

    model =
      if Keyword.get(opts, :stream, false) do
        counter = start_supervised!({Agent, fn -> 0 end})
        %StreamModel{counter: counter, script: script}
      else
        %Test{script: script}
      end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        scene_model: %Test{script: [unexpected]},
        turnmaster_model: %Test{script: [unexpected]}
      )

    on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    {game, pid, before}
  end

  defp record(speaker \\ "El zagal de las cabras") do
    tool_calls([call("record_npc_statement", %{"speaker" => speaker, "statement" => @statement})])
  end

  defp finish(game, pid, before, facts) do
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    world = Game.world(pid)
    assert world.facts == facts
    assert Map.drop(world, [:facts]) == Map.drop(before, [:facts])
    assert Codec.decode(Codec.encode(world)) == world
    assert Games.load_world(Games.get_game(game.id)) == world
    events = Games.list_events(game.id)
    refute Enum.any?(events, &(&1.type == :dice))
    assert Enum.count(events, &(&1.type == :action)) == 1
    assert Enum.count(events, &(&1.type == :narration and &1.actor == "Mara")) == 1

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["complete"] == true)
           ) == 1

    refute Enum.any?(events, &String.contains?(&1.payload["text"] || "", @unrecorded))
    refute_received :unexpected_memory_auxiliary
    events
  end

  test "unrecorded final speech and its deltas stay private until the requested NPC statement commits" do
    owner = self()

    required = fn messages, params ->
      context = messages |> ModelMessages.project() |> Enum.map_join("\n", &(&1["content"] || ""))

      send(
        owner,
        {:memory_required,
         %{
           guide: context =~ "ACLARACIÓN DE TESTIMONIO PENDIENTE",
           speaker: context =~ "el zagal de las cabras"
         }, params.allow_text_output}
      )

      record()
    end

    final = fn _, params ->
      send(owner, {:memory_ready, params.allow_text_output})
      narration(@answer)
    end

    {game, pid, before} =
      boot([narration(@unrecorded), required, final], [@original], stream: true)

    Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game.id}")
    assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
    finish(game, pid, before, [@original, @recorded])
    assert_receive {:memory_required, %{guide: true, speaker: true}, false}
    assert_receive {:memory_ready, _}
    game_id = game.id
    # Public speech comes from the typed field, never raw transport deltas.
    refute_received {:text_delta, ^game_id, _, "dm", @answer}
    refute_received {:text_delta, ^game_id, _, "dm", @unrecorded}
  end

  test "a different speaker cannot acknowledge the requested source or mutate memory before correction" do
    {game, pid, before} = boot([record("Maribel"), record(), narration(@answer)])
    assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
    finish(game, pid, before, [@original, @recorded])
  end

  test "a duplicate retained statement still acknowledges the clarification without renewing its timestamp" do
    {game, pid, before} = boot([record(), narration(@answer)], [@original, @recorded])
    assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
    finish(game, pid, before, before.facts)
  end

  test "restart after the record commits can finish without repeating the question or requiring a new fact" do
    owner = self()

    blocked = fn _, _ ->
      send(owner, {:memory_committed, self()})
      receive do: (:finish -> narration(@answer))
    end

    {game, pid, before} = boot([record(), blocked])
    assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
    assert_receive {:memory_committed, request}, 2_000
    assert Game.world(pid).facts == [@original, @recorded]
    saved = Game.world(pid)
    assert :ok == Game.pause(pid)
    monitor = Process.monitor(request)
    assert {:ok, fresh} = Game.restart(game.id, model: %Test{script: [narration(@answer)]})
    assert_receive {:DOWN, ^monitor, :process, ^request, _}, 1_000
    assert Game.world(fresh) == saved
    assert :ok == Game.resume(fresh)
    finish(game, fresh, before, [@original, @recorded])
  end
end
