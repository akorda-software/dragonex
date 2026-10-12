defmodule Dragonex.GamePCResponseGuidanceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Brief, Codec, Conversation, Game, Games, PCAgent}
  alias ExAgent.{Message, Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @question "Lyra, Vex, ¿qué proponéis hacer ahora para encontrar al forastero y por qué? Espero vuestras respuestas antes de decidir."
  @fact "El zagal afirma: «Quizá sea su lana; no puedo jurarlo.» [Registrado a los 41535 s del reloj del mundo.]"
  @answers %{
    "Lyra" => "Compararía las fuentes antes de elegir; la lana no demuestra su dueño.",
    "Vex" =>
      "Podemos preguntar sin llamar la atención; que nadie lo viera no demuestra que no pasara."
  }

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp fixture do
    {:ok, game} =
      Games.create_game(
        title: "Criterios propios para decidir",
        scene: "El cruce del molino.",
        roster: [
          {Archetypes.wizard(name: "Mara"), :human},
          {%{Archetypes.wizard() | backstory: "Estudié tintes para contrastar testimonios."},
           :ai},
          {%{
             Archetypes.rogue()
             | backstory: "Aprendí a obtener información sin llamar la atención."
           }, :ai}
        ]
      )

    world = %{
      Games.load_world(game)
      | elapsed_seconds: 41_535,
        facts: ["El hilo está en manos de Mara.", @fact],
        scene_refresh_pending: false
    }

    {:ok, _} = Games.save_state(game.id, world, "Mara", world.round, :paused)

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

    {game, world}
  end

  defp callback(actor) do
    parent = self()

    fn messages, _ ->
      send(parent, {:response_guidance_wire, actor, ModelMessages.project(messages)})
      Dragonex.Test.Harness.narration(@answers[actor])
    end
  end

  defp install(pid) do
    for actor <- ["Lyra", "Vex"],
        do:
          assert(
            :ok ==
              Server.set_model(:sys.get_state(pid).pc_agents[actor], %Test{
                script: [callback(actor)]
              })
          )
  end

  defp boot(game) do
    parent = self()

    unexpected = fn _, _ ->
      send(parent, :unexpected_guidance_auxiliary)
      "No debería ejecutarse."
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: [unexpected]},
        scene_model: %Test{script: [unexpected]},
        turnmaster_model: %Test{script: [unexpected]}
      )

    install(pid)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    pid
  end

  defp assert_wire(wire, actor) do
    prompt = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
    assert prompt =~ @question
    assert prompt =~ "CRITERIO PROPIO DE #{actor}"
    assert prompt =~ "ausencia de testimonios no confirma"
    assert prompt =~ "puedes reconocer el acuerdo brevemente"
    assert prompt =~ "Si su respuesta contradice lo registrado, corrige esa diferencia"
    assert prompt =~ @fact
    assert prompt =~ "No necesitas añadir un gesto ni proponer una acción"
    assert prompt =~ "FORMATO DE ESTA RESPUESTA"
    assert prompt =~ "diálogo directo"
    assert prompt =~ "sin acotaciones del narrador"
    assert {archive, _} = :binary.match(prompt, "ARCHIVO")
    assert {sources, _} = :binary.match(prompt, "FUENTES Y CERTEZA")
    assert {criteria, _} = :binary.match(prompt, "CRITERIO PROPIO")
    assert archive < sources and sources < criteria
    assert hd(wire)["content"] =~ "Eres #{actor},"
    assert prompt =~ if(actor == "Lyra", do: "Estudié tintes", else: "Aprendí a obtener")

    if actor == "Vex" do
      assert prompt =~ "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
      assert prompt =~ "Lyra: #{@answers["Lyra"]}"
      assert prompt =~ "no son hechos confirmados"
    else
      refute prompt =~ "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
    end

    Jason.encode!(wire)
  end

  defp finish(game, pid, before) do
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok == Game.pause(pid)

    for actor <- ["Lyra", "Vex"] do
      assert_receive {:response_guidance_wire, ^actor, wire}
      assert_wire(wire, actor)

      if actor == "Vex",
        do:
          assert(
            Enum.any?(
              wire,
              &(&1["role"] == "user" and
                  String.contains?(&1["content"] || "", "CRÓNICA REGISTRADA") and
                  String.contains?(&1["content"] || "", @answers["Lyra"]))
            )
          )
    end

    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Codec.decode(Codec.encode(before)) == before
    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :dice)) == 1
    assert Enum.count(events, &(&1.type == :action)) == 1
    assert Enum.count(events, &(&1.type == :narration and &1.actor == "Mara")) == 1
    refute_received :unexpected_guidance_auxiliary
  end

  test "Game sends current personal criteria after archive and sources to both companions without changing world" do
    {game, before} = fixture()
    pid = boot(game)

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
      finish(game, pid, before)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart keeps the pending question and criteria without repeating the human or spending resources" do
    {game, before} = fixture()
    pid = boot(game)
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:criteria_pending, self()})
      receive do: (:finish -> @answers["Lyra"])
    end

    try do
      assert :ok ==
               Server.set_model(:sys.get_state(pid).pc_agents["Lyra"], %Test{script: [blocked]})

      assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
      assert_receive {:criteria_pending, run}, 2_000
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      ref = Process.monitor(run)
      assert {:ok, fresh} = Game.restart(game.id, model: %Test{label: "No debería ejecutarse."})
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked
      install(fresh)
      assert :ok == Game.resume(fresh)
      finish(game, fresh, before)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart on the second companion recovers the first published intervention without repeating it" do
    {game, before} = fixture()
    pid = boot(game)
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:exchange_pending, self()})
      receive do: (:finish -> @answers["Vex"])
    end

    try do
      assert :ok ==
               Server.set_model(:sys.get_state(pid).pc_agents["Vex"], %Test{script: [blocked]})

      assert {:ok, :resolving} == Game.declare(pid, "Mara", @question)
      assert_receive {:exchange_pending, run}, 2_000
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      assert asked.conversation["pending"] == ["Vex"]
      assert asked.conversation["quiet_close"]["action_seq"] > 0
      ref = Process.monitor(run)
      assert {:ok, fresh} = Game.restart(game.id, model: %Test{label: "No debería ejecutarse."})
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked
      install(fresh)
      assert :ok == Game.resume(fresh)
      finish(game, fresh, before)

      assert Enum.count(
               Games.list_events(game.id),
               &(&1.type == :narration and &1.actor == "Lyra")
             ) == 1
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "compaction cannot replace the committed prior intervention with an overstated summary" do
    {game, before} = fixture()
    {:ok, asked} = Conversation.request("Mara", ["Lyra", "Vex"], @question).(before)

    asked =
      put_in(asked.conversation["quiet_close"], %{
        "action_seq" => 404,
        "world_fingerprint" => Dragonex.Game.ConversationClosure.fingerprint(before)
      })

    {:ok, current} = Conversation.finish_actor("Lyra").(asked)
    parent = self()

    summarizer = %Test{
      script: [
        fn _, _ ->
          send(parent, :exchange_compacted)
          "Lyra confirmó que la lana era del forastero y decidió perseguirlo."
        end
      ]
    }

    agent =
      PCAgent.new(%Test{script: [callback("Vex")]}, before.characters["Vex"],
        summarizer: summarizer,
        compaction_threshold: 1,
        compaction_keep_recent: 1
      )

    server = start_supervised!({Server, agent: agent, agent_id: "exchange-#{game.id}"})

    history =
      for text <- ["DIÁLOGO AJENO", "Hablaron de la ruta.", "El molino sigue aquí."],
          do: Message.new_request([%Message.Part.User{content: text}])

    events = [
      %{
        seq: 404,
        type: :action,
        actor: "Mara",
        visible_to: "all",
        payload: %{"text" => @question}
      },
      %{
        seq: 405,
        type: :narration,
        actor: "Lyra",
        visible_to: "all",
        payload: %{"complete" => true, "text" => @answers["Lyra"]}
      }
    ]

    prompt =
      Brief.turn_prompt(
        current,
        "Vex",
        PCAgent.instruction("Vex", current.characters["Vex"], current)
      ) <>
        PCAgent.response_guidance(current, "Vex", events)

    assert {:ok, _} = Dragonex.Agent.chat(server, prompt, message_history: history)
    assert_receive :exchange_compacted
    assert_receive {:response_guidance_wire, "Vex", wire}
    all = Enum.map_join(wire, "\n", &(&1["content"] || ""))
    assert all =~ "Lyra confirmó que la lana"
    refute all =~ "DIÁLOGO AJENO"
    latest = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
    assert latest =~ "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
    assert latest =~ "Lyra: #{@answers["Lyra"]}"
    assert latest =~ @fact
    refute latest =~ "Lyra confirmó que la lana"
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Codec.decode(Codec.encode(current)) == current
    Jason.encode!(wire)
  end

  test "compaction retains current background and pending recommendation over an overstated earlier summary" do
    {game, before} = fixture()
    {:ok, asked} = Conversation.request("Mara", ["Lyra"], @question).(before)
    current = put_in(asked.characters["Lyra"].backstory, "Busco pruebas antes de acusar.")
    parent = self()

    summarizer = %Test{
      script: [
        fn _, _ ->
          send(parent, :criteria_compacted)
          "Ambos decidieron viajar y si no hay testigos no pasó por allí."
        end
      ]
    }

    model = %Test{script: [callback("Lyra")]}

    agent =
      PCAgent.new(model, %{before.characters["Lyra"] | backstory: "TRASFONDO ANTIGUO"},
        summarizer: summarizer,
        compaction_threshold: 1,
        compaction_keep_recent: 1
      )

    server = start_supervised!({Server, agent: agent, agent_id: "criteria-#{game.id}"})

    history =
      for text <- ["DIÁLOGO ANTIGUO", "Hablaron de la ruta.", "El molino sigue aquí."],
          do: Message.new_request([%Message.Part.User{content: text}])

    prompt =
      Brief.turn_prompt(
        current,
        "Lyra",
        PCAgent.instruction("Lyra", current.characters["Lyra"], current)
      ) <> apply(PCAgent, :response_guidance, [current, "Lyra"])

    assert {:ok, _} = Dragonex.Agent.chat(server, prompt, message_history: history)
    assert_receive :criteria_compacted
    assert_receive {:response_guidance_wire, "Lyra", wire}
    all = Enum.map_join(wire, "\n", &(&1["content"] || ""))
    assert all =~ "Ambos decidieron viajar"
    refute all =~ "DIÁLOGO ANTIGUO"
    latest = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
    assert latest =~ "CRITERIO PROPIO DE Lyra"
    assert latest =~ "Busco pruebas antes de acusar"
    refute latest =~ "TRASFONDO ANTIGUO"
    assert latest =~ "decisión sigue siendo del jugador"
    assert latest =~ "No repitas todo su resumen"
    assert latest =~ @fact
    assert Games.load_world(Games.get_game(game.id)) == before
    Jason.encode!(wire)
  end
end
