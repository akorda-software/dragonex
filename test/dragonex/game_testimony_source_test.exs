defmodule Dragonex.GameTestimonySourceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Brief, Codec, DM, Game, Games, PCAgent}
  alias Dragonex.Game.Instructions
  alias ExAgent.{Message, Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @clue "Un hilo de lana oscura apareció donde se pierden las huellas."
  @claim "El zagal de las cabras afirma: «''Ese hilo es del mismo gris apagado del abrigo del forastero, pero lo vi de lejos y no puedo jurar que sea la misma lana; eso sigue siendo una suposición.''» [Registrado a los 41535 s del reloj del mundo.]"
  @latest "el zagal de las cabras afirma: «Vi al forastero de lejos, no su tela de cerca. El hilo lo sé por lo que me contáis; no puedo confirmar que sea del abrigo.» [Registrado a los 41535 s del reloj del mundo.]"
  @last_marker "Última entrada conservada de esta fuente (no confirma su contenido):"
  @question "Lyra, Vex, ¿qué sabemos ahora del hilo y qué parte sigue siendo solo la impresión del zagal? Espero vuestras respuestas."
  @wrong "El grupo vio el abrigo gris del forastero."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp fixture do
    {:ok, game} =
      Games.create_game(
        title: "El testigo conserva su voz",
        scene: "El cruce del molino.",
        roster: [
          {Archetypes.wizard(name: "Mara"), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    world = %{
      Games.load_world(game)
      | facts: [@clue, @claim, @latest],
        elapsed_seconds: 41_535,
        scene_refresh_pending: false
    }

    {:ok, _} = Games.save_state(game.id, world, "Mara", world.round, :paused)
    {game, world}
  end

  defp assert_sources(prompt) do
    [confirmed, testimony] =
      String.split(prompt, "Testimonios atribuidos (contenido sin confirmar):", parts: 2)

    assert confirmed =~ @clue
    refute confirmed =~ @claim
    refute confirmed =~ @latest
    assert testimony =~ @claim
    assert testimony =~ "#{@last_marker}\n- #{@latest}"
    refute testimony =~ "#{@last_marker}\n- #{@claim}"
    assert testimony =~ "orden conservado"
    assert prompt =~ "FUENTES Y CERTEZA"
    assert prompt =~ "prosa anterior"
    assert prompt =~ "Si una entrada posterior aclara"
  end

  test "real Game PC replies receive sources after the bounded dice archive and preserve the world" do
    {game, before} = fixture()

    {:ok, _} =
      Games.append_event(game.id, :dice, "Mara", "all", %{
        who: "Mara",
        dice: [[20, 20]],
        total: 23,
        against: ["dc", 15],
        outcome: :success,
        reason: "chequeo antiguo",
        kind: :check
      })

    for n <- 1..401,
        do: Games.append_event(game.id, :system, "dm", "all", %{note: "Recuerdo #{n}."})

    old_events = Games.list_events(game.id)
    parent = self()

    unexpected = fn _, _ ->
      send(parent, :unexpected_source_request)
      "Respuesta auxiliar inesperada."
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: [unexpected]},
        scene_model: %Test{script: [unexpected]},
        turnmaster_model: %Test{script: [unexpected]}
      )

    try do
      state = :sys.get_state(pid)

      for actor <- ["Lyra", "Vex"] do
        callback = fn messages, _ ->
          send(parent, {:source_request, actor, ModelMessages.project(messages)})
          narration("Según el zagal, el color coincide; no demuestra de quién es el hilo.")
        end

        assert :ok == Server.set_model(state.pc_agents[actor], %Test{script: [callback]})
      end

      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
      assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
      assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
      assert :ok == Game.pause(pid)

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:source_request, ^actor, wire}
        prompt = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
        assert_sources(prompt)
        assert {archive, _} = :binary.match(prompt, "ARCHIVO")
        assert {sources, _} = :binary.match(prompt, "FUENTES Y CERTEZA")
        assert archive < sources

        assert Enum.any?(
                 wire,
                 &(&1["role"] == "system" and
                     String.contains?(&1["content"] || "", "Eres #{actor},"))
               )
      end

      refute_received :unexpected_source_request
      refute_received {:source_request, _, _}
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert Codec.decode(Codec.encode(before)) == before
      events = Games.list_events(game.id)
      assert Enum.take(events, length(old_events)) == old_events
      assert Enum.count(events, &(&1.type == :dice)) == 1
      assert Enum.count(events, &(&1.type == :action)) == 1
      assert Enum.count(events, &(&1.type == :narration and &1.actor == "Mara")) == 1
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart between companion replies preserves both versions and their retained order" do
    {game, before} = fixture()
    parent = self()

    unexpected = fn _, _ ->
      send(parent, :unexpected_source_request)
      "Respuesta auxiliar inesperada."
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: [unexpected]},
        scene_model: %Test{script: [unexpected]},
        turnmaster_model: %Test{script: [unexpected]}
      )

    callback = fn actor ->
      fn messages, _ ->
        send(parent, {:source_request, actor, ModelMessages.project(messages)})

        narration(
          "Según su aclaración, el zagal conoce el hilo por lo que le contamos; no confirma su dueño."
        )
      end
    end

    blocked = fn _, _ ->
      send(parent, {:source_pending, self()})
      receive do: (:finish -> narration("Sigo sin saber quién perdió el hilo."))
    end

    try do
      state = :sys.get_state(pid)
      assert :ok == Server.set_model(state.pc_agents["Lyra"], %Test{script: [callback.("Lyra")]})
      assert :ok == Server.set_model(state.pc_agents["Vex"], %Test{script: [blocked]})
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
      assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
      assert_receive {:source_pending, run}, 2_000
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      assert asked.conversation["pending"] == ["Vex"]
      assert asked.facts == before.facts
      ref = Process.monitor(run)
      assert {:ok, fresh} = Game.restart(game.id, model: %Test{script: [unexpected]})
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked

      assert :ok ==
               Server.set_model(:sys.get_state(fresh).pc_agents["Vex"], %Test{
                 script: [callback.("Vex")]
               })

      assert :ok == Game.resume(fresh)
      assert :ok == Game.await(fresh, &(&1.current == "Mara" and &1.status == :waiting))
      assert :ok == Game.pause(fresh)

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:source_request, ^actor, wire}
        prompt = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
        assert_sources(prompt)
      end

      refute_received {:source_request, _, _}
      refute_received :unexpected_source_request
      assert Game.world(fresh) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      events = Games.list_events(game.id)
      assert Enum.count(events, &(&1.type == :action)) == 1

      for actor <- ["Mara", "Lyra", "Vex"],
          do: assert(Enum.count(events, &(&1.type == :narration and &1.actor == actor)) == 1)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  for role <- [:dm, :pc] do
    test "#{role} receives current attributed sources after a misleading history compaction" do
      assert_compacted_sources(unquote(role))
    end
  end

  defp assert_compacted_sources(role) do
    {game, world} = fixture()
    parent = self()

    summarizer = %Test{
      script: [
        fn _, _ ->
          send(parent, {:source_summary, role})
          @wrong
        end
      ]
    }

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:compacted_sources, role, ModelMessages.project(messages)})
          narration("Queda por comprobar esa versión.")
        end
      ]
    }

    opts = [summarizer: summarizer, compaction_threshold: 1, compaction_keep_recent: 1]

    agent =
      if role == :dm,
        do: DM.new(model, opts),
        else: PCAgent.new(model, Archetypes.wizard(), opts)

    server = start_supervised!({Server, agent: agent, agent_id: "source-#{game.id}-#{role}"})

    history =
      for text <- [
            "DIÁLOGO ANTIGUO: el zagal habló del color.",
            "Miraron la compuerta.",
            "La compuerta está rota."
          ],
          do: Message.new_request([%Message.Part.User{content: text}])

    actor = if role == :dm, do: "dm", else: "Lyra"

    prompt =
      Brief.turn_prompt(world, actor, "Recuerda lo que sabemos.") <>
        apply(Instructions, :testimony_instruction, [world, actor])

    assert {:ok, _} = Dragonex.Agent.chat(server, prompt, message_history: history)
    assert_receive {:source_summary, ^role}
    assert_receive {:compacted_sources, ^role, wire}
    content = Enum.map_join(wire, "\n", &(&1["content"] || ""))
    assert content =~ @wrong
    refute content =~ "DIÁLOGO ANTIGUO"
    current = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
    assert_sources(current)
    assert current =~ "41535 s del reloj del mundo"

    assert Enum.any?(
             wire,
             &(&1["role"] == "system" and
                 String.contains?(
                   &1["content"] || "",
                   if(role == :dm, do: "Dungeon Master", else: "Eres Lyra,")
                 ))
           )

    assert Games.load_world(Games.get_game(game.id)) == world
    Jason.encode!(wire)
  end
end
