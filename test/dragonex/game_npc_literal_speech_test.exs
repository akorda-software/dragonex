defmodule Dragonex.GameNPCLiteralSpeechTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, History}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  @question "Le pregunto a la tabernera: «¿Qué plato sirves hoy y cuánto cuesta?» Espero junto a la barra su respuesta antes de pedir."
  @speech "—¿Qué plato sirves hoy y cuánto cuesta?"
  @answer "Maribel señala el caldero. —Tres monedas el plato; para ti sigue en pie mi invitación."
  @goatherd_question "Le pregunto al zagal de las cabras: «¿Viste al forastero tomar el camino del norte y qué te dijo sobre las semillas?» Espero aquí su respuesta."
  @goatherd_speech "—¿Viste al forastero tomar el camino del norte y qué te dijo sobre las semillas?"
  @source_question "Le pregunto al zagal de las cabras: «¿De qué dirección venía el forastero que viste hace dos días al caer la tarde, antes de tomar el camino del norte, y recuerdas si llevaba algo además del abrigo oscuro?»"
  @source_speech "—¿De qué dirección venía el forastero que viste hace dos días al caer la tarde, antes de tomar el camino del norte, y recuerdas si llevaba algo además del abrigo oscuro?"
  @clarification_question "Le pregunto al zagal de las cabras: «Cuando dijiste que lo viste de lejos, ¿te referías al forastero, a su abrigo o al hilo? ¿Llegaste a ver de cerca la lana de su abrigo?» Espero aquí su respuesta."
  @clarification_speech "—Cuando dijiste que lo viste de lejos, ¿te referías al forastero, a su abrigo o al hilo? ¿Llegaste a ver de cerca la lana de su abrigo?"
  @named_question "Le pregunto a Ada: «¿Cuándo viste el farol por última vez? ¿Desde dónde lo viste? ¿Sabes si sigue allí?» Espero aquí su respuesta."
  @named_speech "—¿Cuándo viste el farol por última vez? ¿Desde dónde lo viste? ¿Sabes si sigue allí?"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(model, opts \\ []) do
    wizard = %{
      Archetypes.wizard(name: "Thane")
      | spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
    }

    {:ok, game} =
      Games.create_game(
        title: "Una pregunta humana sin paráfrasis",
        scene: "El interior de la taberna.",
        roster: [
          {wizard, :human},
          {Archetypes.rogue(name: Keyword.get(opts, :pc_name, "Vex")), :ai}
        ]
      )

    loaded = Games.load_world(game)
    before = %{loaded | facts: Keyword.get(opts, :facts, loaded.facts)}
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :literal_tm_called)
          "(no decision)"
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id, model: model, turnmaster_model: tm, roller: fn 4 -> 1 end)

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before}
  end

  defp wait(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  test "the single model request belongs to the NPC response and reads the human's exact speech" do
    parent = self()

    callback = fn messages, _ ->
      send(parent, {:literal_request, inspect(messages, limit: :infinity)})
      narration(@answer)
    end

    {game, pid, before} = boot(%Test{script: [callback, callback]})
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
    wait(pid)
    assert_receive {:literal_request, context}
    assert context =~ "Responde como ese PNJ"
    assert context =~ @speech
    refute_received {:literal_request, _}
    refute_received :literal_tm_called
    events = Games.list_events(game.id)
    assert ["Thane", "dm"] == Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor)

    assert [%{payload: %{"text" => @speech, "complete" => true}}] =
             Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute Enum.any?(events, &(&1.type == :dice))
    assert inspect(History.from_events(events), limit: :infinity) =~ @speech
  end

  test "the real prepositional NPC question skips the human model and keeps attributed memory" do
    owner = self()
    statement = "Lo vi venir del pueblo con un hatillo a la espalda."
    answer = "El zagal responde. —Venía del pueblo con un hatillo."

    npc = fn messages, _ ->
      context = inspect(messages, limit: :infinity)
      npc? = String.contains?(context, "Responde como ese PNJ")
      send(owner, {:preposition_npc, npc?, String.contains?(context, @source_speech)})

      if npc?,
        do:
          tool_calls([
            call("record_npc_statement", %{
              "speaker" => "El zagal de las cabras",
              "statement" => statement
            })
          ]),
        else: "No es la frase original."
    end

    {game, pid, before} = boot(%Test{script: [npc, narration(answer)]})

    try do
      assert {:ok, :resolving} = Game.declare(pid, "Thane", @source_question)
      wait(pid)
      assert_receive {:preposition_npc, true, true}
      refute_received {:preposition_npc, _, _}
      refute_received :literal_tm_called
      events = Games.list_events(game.id)
      assert ["Thane", "dm"] == Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor)

      assert [%{payload: %{"text" => @source_speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      world = Game.world(pid)
      assert Map.drop(world, [:facts]) == Map.drop(before, [:facts])

      assert world.facts ==
               before.facts ++
                 [
                   "El zagal de las cabras afirma: «#{statement}» [Registrado a los 0 s del reloj del mundo.]"
                 ]

      assert Games.load_world(Games.get_game(game.id)) == world
      refute Enum.any?(events, &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "the compound clarification skips human narration and records only a new attributed statement" do
    owner = self()
    statement = "Me refería al forastero; no vi de cerca la lana de su abrigo."
    answer = "El zagal responde. —Al forastero; no vi de cerca la lana."

    npc = fn messages, _ ->
      context = inspect(messages, limit: :infinity)

      send(
        owner,
        {:clarification_context, String.contains?(context, "Responde como ese PNJ"),
         String.contains?(context, @clarification_speech),
         String.contains?(context, "usa record_npc_statement antes de narrarla")}
      )

      tool_calls([
        call("record_npc_statement", %{
          "speaker" => "El zagal de las cabras",
          "statement" => statement
        })
      ])
    end

    original =
      "El zagal de las cabras afirma: «Ese hilo es del mismo gris del abrigo, pero lo vi de lejos y no puedo jurar que sea la misma lana.» [Registrado a los 0 s del reloj del mundo.]"

    {game, pid, before} = boot(%Test{script: [npc, narration(answer)]}, facts: [original])

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @clarification_question)
      wait(pid)
      assert_receive {:clarification_context, true, true, true}
      refute_received {:clarification_context, _, _, _}
      refute_received :literal_tm_called
      events = Games.list_events(game.id)
      assert ["Thane", "dm"] == Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor)

      assert [%{payload: %{"text" => @clarification_speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      world = Game.world(pid)
      assert Map.drop(world, [:facts]) == Map.drop(before, [:facts])

      assert world.facts ==
               before.facts ++
                 [
                   "El zagal de las cabras afirma: «#{statement}» [Registrado a los 0 s del reloj del mundo.]"
                 ]

      assert Games.load_world(Games.get_game(game.id)) == world
      refute Enum.any?(events, &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart while the NPC response is waiting preserves one human speech and the original request" do
    parent = self()

    callback = fn messages, _ ->
      send(parent, {:literal_waiting, self(), inspect(messages, limit: :infinity)})
      receive do: (:finish -> narration(@answer))
    end

    {game, pid, before} = boot(%Test{script: [callback]})
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
    assert_receive {:literal_waiting, run, context}, 2_000
    assert context =~ "Responde como ese PNJ"
    assert context =~ @speech
    assert :ok == Game.pause(pid)
    asked = Game.world(pid)
    assert Game.current(pid) == "dm"
    assert asked.conversation["question"] == @question
    monitor = Process.monitor(run)
    {:ok, fresh} = Game.restart(game.id, model: %Test{script: [narration(@answer)]})
    assert fresh != pid
    assert_receive {:DOWN, ^monitor, :process, ^run, _}, 1_000
    assert Game.world(fresh) == asked
    assert :ok == Game.resume(fresh)
    wait(fresh)
    assert Game.world(fresh) == before
    events = Games.list_events(game.id)
    assert length(Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))) == 1
    assert Enum.count(events, &(&1.type == :narration and &1.payload["text"] == @answer)) == 1
    refute_received :literal_tm_called
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "a named NPC request survives restart with exact human speech and attributed memory" do
    parent = self()
    statement = "Vi el farol ayer desde la puerta; no sé si sigue allí."
    answer = "Ada responde. —Lo vi ayer desde la puerta; no sé si sigue allí."

    callback = fn messages, _ ->
      context = inspect(messages, limit: :infinity)

      send(
        parent,
        {:named_waiting, self(), String.contains?(context, "Responde como ese PNJ"),
         String.contains?(context, @named_speech)}
      )

      receive do: (:finish -> narration(answer))
    end

    {game, pid, before} = boot(%Test{script: [callback]})

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @named_question)
      assert_receive {:named_waiting, run, true, true}, 2_000
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      assert asked.conversation["question"] == @named_question
      assert asked.conversation["world_recipient"] == "ada"
      monitor = Process.monitor(run)

      script = [
        tool_calls([
          call("record_npc_statement", %{"speaker" => "Ada", "statement" => statement})
        ]),
        narration(answer)
      ]

      {:ok, fresh} = Game.restart(game.id, model: %Test{script: script})
      assert_receive {:DOWN, ^monitor, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked
      assert :ok == Game.resume(fresh)
      wait(fresh)

      expected = %{
        before
        | facts:
            before.facts ++
              ["Ada afirma: «#{statement}» [Registrado a los 0 s del reloj del mundo.]"]
      }

      assert Game.world(fresh) == expected
      assert Games.load_world(Games.get_game(game.id)) == expected
      events = Games.list_events(game.id)

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "Thane" and
                   &1.payload["text"] == @named_speech and &1.payload["complete"])
             ) == 1

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == answer)
             ) == 1

      refute Enum.any?(events, &(&1.type == :dice))
      refute_received :literal_tm_called
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a question followed by a spell still resolves its real slot and dice through the human beat" do
    for question <- [
          @question,
          "Le pregunto a la posadera: «¿Viste tú misma marcharse al forastero o te lo contó alguien?» Espero aquí su respuesta.",
          @goatherd_question,
          @source_question,
          @clarification_question,
          @named_question
        ] do
      assert_spell_resolution(question)
    end
  end

  test "the goatherd alone responds to exact speech and records his own attributed statement" do
    parent = self()
    answer = "El zagal señala el norte. —Lo vi pasar por aquí, pero no me habló de semillas."
    statement = "Vi al forastero tomar el camino del norte; no me habló de semillas."

    npc = fn messages, _ ->
      context = inspect(messages, limit: :infinity)

      send(
        parent,
        {:goatherd_context, String.contains?(context, "Responde como ese PNJ"),
         String.contains?(context, @goatherd_speech)}
      )

      tool_calls([
        call("record_npc_statement", %{
          "speaker" => "El zagal de las cabras",
          "statement" => statement
        })
      ])
    end

    {game, pid, before} = boot(%Test{script: [npc, narration(answer)]})

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @goatherd_question)
      wait(pid)
      assert_receive {:goatherd_context, true, true}
      refute_received {:goatherd_context, _, _}
      refute_received :literal_tm_called
      events = Games.list_events(game.id)
      assert ["Thane", "dm"] == Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor)

      assert [%{payload: %{"text" => @goatherd_speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      after_world = Game.world(pid)
      assert Map.drop(after_world, [:facts]) == Map.drop(before, [:facts])

      assert after_world.facts ==
               before.facts ++
                 [
                   "El zagal de las cabras afirma: «#{statement}» [Registrado a los 0 s del reloj del mundo.]"
                 ]

      assert Games.load_world(Games.get_game(game.id)) == after_world

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == answer)
             ) == 1

      refute Enum.any?(events, &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a role label matching a registered PC retains the human resolution beat" do
    parent = self()

    human = fn messages, _ ->
      context = inspect(messages, limit: :infinity)

      send(
        parent,
        {:role_collision_human, self(),
         String.contains?(context, "Estás resolviendo SOLO lo que Thane")}
      )

      receive do: (:finish -> narration("—¿Qué sabes del camino?"))
    end

    {game, pid, before} = boot(%Test{script: [human]}, pc_name: "El Zagal")

    try do
      assert {:ok, :resolving} ==
               Game.declare(pid, "Thane", "Le pregunto al zagal: ¿Qué sabes del camino?")

      assert_receive {:role_collision_human, run, true}, 2_000
      assert Game.world(pid).conversation == nil
      assert :ok == Game.pause(pid)
      send(run, :finish)
      assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      events = Games.list_events(game.id)
      assert ["Thane"] == Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor)

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "Thane" and &1.payload["complete"])
             ) == 1

      refute Enum.any?(events, &(&1.type == :dice))
      refute_received :literal_tm_called
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "qualified goatherd request survives restart without duplicating the human speech" do
    for {question, speech} <- [
          {@goatherd_question, @goatherd_speech},
          {@source_question, @source_speech},
          {@clarification_question, @clarification_speech}
        ] do
      parent = self()
      answer = "El zagal responde. —Lo vi junto al molino."

      npc = fn messages, _ ->
        context = inspect(messages, limit: :infinity)
        send(parent, {:goatherd_waiting, self(), String.contains?(context, speech)})
        receive do: (:finish -> narration(answer))
      end

      {game, pid, before} = boot(%Test{script: [npc]})

      try do
        assert {:ok, :resolving} == Game.declare(pid, "Thane", question)
        assert_receive {:goatherd_waiting, run, true}, 2_000
        assert :ok == Game.pause(pid)
        asked = Game.world(pid)
        assert asked.conversation["question"] == question
        assert asked.conversation["world_recipient"] == "el zagal de las cabras"
        monitor = Process.monitor(run)
        needs_memory = question == @clarification_question
        statement = "No puedo aclarar a qué me refería; no vi la lana de cerca."

        script =
          if needs_memory do
            [
              tool_calls([
                call("record_npc_statement", %{
                  "speaker" => "El zagal de las cabras",
                  "statement" => statement
                })
              ]),
              narration(answer)
            ]
          else
            [narration(answer)]
          end

        expected =
          if needs_memory do
            %{
              before
              | facts:
                  before.facts ++
                    [
                      "El zagal de las cabras afirma: «#{statement}» [Registrado a los 0 s del reloj del mundo.]"
                    ]
            }
          else
            before
          end

        {:ok, fresh} = Game.restart(game.id, model: %Test{script: script})
        assert fresh != pid
        assert_receive {:DOWN, ^monitor, :process, ^run, _}, 1_000
        assert Game.world(fresh) == asked
        assert :ok == Game.resume(fresh)
        wait(fresh)
        assert Game.world(fresh) == expected
        assert Games.load_world(Games.get_game(game.id)) == expected
        events = Games.list_events(game.id)

        assert Enum.count(
                 events,
                 &(&1.type == :narration and &1.actor == "Thane" and
                     &1.payload["text"] == speech)
               ) == 1

        assert Enum.count(
                 events,
                 &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == answer)
               ) == 1

        refute_received :literal_tm_called
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end

  defp assert_spell_resolution(question) do
    parent = self()
    mixed = question <> " Después lanzo False Life sobre mí."

    human = fn messages, _ ->
      send(parent, {:mixed_human_context, inspect(messages, limit: :infinity)})

      tool_calls([
        call("cast_spell", %{"caster" => "Thane", "target" => "Thane", "spell" => "false life"})
      ])
    end

    {game, pid, before} =
      boot(%Test{script: [human, narration("La magia me protege."), narration(@answer)]})

    assert {:ok, :resolving} == Game.declare(pid, "Thane", mixed)
    wait(pid)
    assert_receive {:mixed_human_context, context}
    assert context =~ "Estás resolviendo SOLO lo que Thane"
    assert Game.world(pid).characters["Thane"].temp_hp == 5
    assert Game.world(pid).spell_slots["Thane"][1] == before.spell_slots["Thane"][1] - 1
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
    assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
    refute_received :literal_tm_called
  end
end
