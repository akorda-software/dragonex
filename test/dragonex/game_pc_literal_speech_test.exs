defmodule Dragonex.GamePCLiteralSpeechTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, History}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @question "Lyra, Vex, ¿qué recordáis de cómo terminó el combate en el granero? Espero vuestras respuestas antes de decidir qué hacer."
  @speech "—Lyra, Vex, ¿qué recordáis de cómo terminó el combate en el granero?"
  @answer "La taberna permanece tranquila."
  @opinion "Lyra, Vex, ¿qué os parece ir al cruce del molino a hablar con el zagal? Espero vuestras respuestas antes de decidir."
  @opinion_speech "—Lyra, Vex, ¿qué os parece ir al cruce del molino a hablar con el zagal?"
  @preposition "Lyra, Vex, ¿De qué dirección dijo el zagal que venía el forastero? Espero vuestras respuestas."
  @preposition_speech "—Lyra, Vex, ¿De qué dirección dijo el zagal que venía el forastero?"
  @multiple "Lyra, Vex, ¿qué cambia la última aclaración del zagal para nuestra pista del hilo? ¿Qué proponéis hacer ahora y por qué? Espero vuestras respuestas antes de decidir."
  @multiple_speech "—Lyra, Vex, ¿qué cambia la última aclaración del zagal para nuestra pista del hilo? ¿Qué proponéis hacer ahora y por qué?"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp closure do
    parent = self()

    fn messages, _ ->
      send(parent, {:pc_literal_world_request, ModelMessages.project(messages)})
      narration(@answer)
    end
  end

  defp response(actor) do
    parent = self()

    fn messages, _ ->
      send(parent, {:pc_literal_response, actor, ModelMessages.project(messages)})
      narration("—Recuerdo la flecha de Vex.")
    end
  end

  defp boot(model, lyra \\ nil) do
    wizard = %{
      Archetypes.wizard(name: "Thane")
      | spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
    }

    {:ok, game} =
      Games.create_game(
        title: "Una pregunta sin gestos inventados",
        scene: "La taberna permanece tranquila.",
        roster: [{wizard, :human}, {Archetypes.wizard(), :ai}, {Archetypes.rogue(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :pc_literal_tm_request)
          "(no decision)"
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id, model: model, turnmaster_model: tm, roller: fn 4 -> 1 end)

    state = :sys.get_state(pid)

    assert :ok ==
             Server.set_model(state.pc_agents["Lyra"], %Test{script: [lyra || response("Lyra")]})

    assert :ok == Server.set_model(state.pc_agents["Vex"], %Test{script: [response("Vex")]})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before}
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  test "one literal human speech reaches both agents without a human model request" do
    callback = closure()
    {game, pid, before} = boot(%Test{script: [callback, callback]})

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(pid)
      refute_received {:pc_literal_world_request, _}

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:pc_literal_response, ^actor, context}
        assert Enum.any?(context, &ModelMessages.imported?(&1, @speech))
        assert Enum.any?(context, &(&1["role"] == "system" and &1["content"] =~ "Eres #{actor},"))
        assert List.last(Enum.filter(context, &(&1["role"] == "user")))["content"] =~ @question
      end

      events = Games.list_events(game.id)

      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert [%{payload: %{"text" => @speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert inspect(History.from_events(events), limit: :infinity) =~ @speech
      refute Enum.any?(events, &(&1.type == :dice))
      refute_received :pc_literal_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a prepositional question reaches each PC once and closes without another narrator" do
    callback = closure()
    {game, pid, before} = boot(%Test{script: [callback, callback]})

    try do
      assert {:ok, :resolving} = Game.declare(pid, "Thane", @preposition)
      finish(pid)
      refute_received {:pc_literal_world_request, _}

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:pc_literal_response, ^actor, wire}

        assert Enum.any?(
                 wire,
                 &ModelMessages.imported?(&1, @preposition_speech)
               )

        assert Enum.any?(wire, &(&1["role"] == "system" and &1["content"] =~ "Eres #{actor},"))
        refute_received {:pc_literal_response, ^actor, _}
      end

      refute_received :pc_literal_tm_request
      events = Games.list_events(game.id)

      assert ["Thane", "Lyra", "Vex"] ==
               Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor)

      assert [%{payload: %{"text" => @preposition_speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute Enum.any?(events, &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "the real double question reaches both companions verbatim and returns without another narrator" do
    callback = closure()
    {game, pid, before} = boot(%Test{script: [callback, callback]})
    old_events = Games.list_events(game.id)

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @multiple)
      finish(pid)
      refute_received {:pc_literal_world_request, _}
      refute_received :pc_literal_tm_request

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:pc_literal_response, ^actor, wire}
        assert Enum.any?(wire, &ModelMessages.imported?(&1, @multiple_speech))
        prompt = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
        assert prompt =~ @multiple
        assert hd(wire)["content"] =~ "Eres #{actor},"
        if actor == "Vex", do: assert(prompt =~ "Lyra: —Recuerdo la flecha de Vex.")
        refute_received {:pc_literal_response, ^actor, _}
      end

      events = Games.list_events(game.id)
      assert Enum.take(events, length(old_events)) == old_events
      events = Enum.drop(events, length(old_events))

      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert [%{payload: %{"text" => @multiple_speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      assert Enum.map(Enum.filter(events, &(&1.type == :narration)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute Enum.any?(events, &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart during the first response keeps the question and a single literal human speech" do
    for {question, speech} <- [
          {@question, @speech},
          {@opinion, @opinion_speech},
          {@preposition, @preposition_speech},
          {@multiple, @multiple_speech}
        ] do
      parent = self()

      blocked = fn messages, _ ->
        send(parent, {:pc_literal_waiting, self(), ModelMessages.project(messages)})
        receive do: (:finish -> narration("—Recuerdo la flecha."))
      end

      callback = closure()
      {game, pid, before} = boot(%Test{script: [callback, callback]}, blocked)

      try do
        assert {:ok, :resolving} == Game.declare(pid, "Thane", question)
        assert_receive {:pc_literal_waiting, run, context}, 2_000
        assert Enum.any?(context, &ModelMessages.imported?(&1, speech))
        assert :ok == Game.pause(pid)
        asked = Game.world(pid)
        assert asked.conversation["question"] == question
        assert asked.conversation["pending"] == ["Lyra", "Vex"]
        ref = Process.monitor(run)
        assert {:ok, fresh} = Game.restart(game.id, model: %Test{script: [callback]})
        assert fresh != pid
        assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
        assert Game.world(fresh) == asked
        state = :sys.get_state(fresh)

        for actor <- ["Lyra", "Vex"],
            do:
              assert(
                :ok == Server.set_model(state.pc_agents[actor], %Test{script: [response(actor)]})
              )

        assert :ok == Game.resume(fresh)
        finish(fresh)
        events = Games.list_events(game.id)

        assert Enum.count(
                 events,
                 &(&1.type == :narration and &1.actor == "Thane" and &1.payload["text"] == speech)
               ) == 1

        assert Enum.map(
                 Enum.filter(events, &(&1.type == :turn and &1.actor == "Thane")),
                 & &1.actor
               ) == ["Thane"]

        assert Game.world(fresh) == before
        assert Games.load_world(Games.get_game(game.id)) == before
        refute Enum.any?(events, &(&1.type == :dice))
        refute_received :pc_literal_tm_request
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end

  test "the live opinion question reaches both companions verbatim without a human narration run" do
    {game, pid, before} = boot(%Test{script: [closure()]})

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @opinion)
      finish(pid)

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:pc_literal_response, ^actor, context}

        assert Enum.any?(
                 context,
                 &ModelMessages.imported?(&1, @opinion_speech)
               )

        assert List.last(Enum.filter(context, &(&1["role"] == "user")))["content"] =~ @opinion
      end

      events = Games.list_events(game.id)

      assert [%{payload: %{"text" => @opinion_speech, "complete" => true}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

      assert Enum.map(
               Enum.filter(events, &(&1.type == :narration and &1.payload["turn_id"] != nil)),
               & &1.actor
             ) == ["Thane", "Lyra", "Vex"]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute Enum.any?(events, &(&1.type == :dice))
      refute_received {:pc_literal_world_request, _}
      refute_received :pc_literal_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "an opinion followed by False Life keeps the human tool request and its actual cost" do
    for question <- [@opinion, @preposition, @multiple] do
      parent = self()

      human = fn messages, _ ->
        send(parent, {:pc_opinion_mixed_human, ModelMessages.project(messages)})

        tool_calls([
          call("cast_spell", %{"caster" => "Thane", "target" => "Thane", "spell" => "false life"})
        ])
      end

      {game, pid, before} =
        boot(%Test{script: [human, narration("La magia me protege."), closure()]})

      try do
        assert {:ok, :resolving} ==
                 Game.declare(pid, "Thane", question <> " Después lanzo False Life sobre mí.")

        finish(pid)
        assert_receive {:pc_opinion_mixed_human, wire}

        assert List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"] =~
                 "Estás resolviendo SOLO"

        world = Game.world(pid)
        assert world.characters["Thane"].temp_hp == 5
        assert world.spell_slots["Thane"][1] == before.spell_slots["Thane"][1] - 1
        assert world.elapsed_seconds == before.elapsed_seconds
        assert world.conversation == nil
        assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
        assert Games.load_world(Games.get_game(game.id)) == world
        refute_received :pc_literal_tm_request
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end

  test "a memory question followed by False Life retains the human tool beat and pays once" do
    parent = self()

    human = fn messages, _ ->
      send(parent, {:pc_literal_mixed_human, ModelMessages.project(messages)})

      tool_calls([
        call("cast_spell", %{"caster" => "Thane", "target" => "Thane", "spell" => "false life"})
      ])
    end

    {game, pid, before} =
      boot(%Test{script: [human, narration("La magia me protege."), closure()]})

    try do
      assert {:ok, :resolving} ==
               Game.declare(pid, "Thane", @question <> " Después lanzo False Life sobre mí.")

      finish(pid)
      assert_receive {:pc_literal_mixed_human, wire}

      assert List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"] =~
               "Estás resolviendo SOLO"

      assert Game.world(pid).characters["Thane"].temp_hp == 5
      assert Game.world(pid).spell_slots["Thane"][1] == before.spell_slots["Thane"][1] - 1
      assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
      assert Game.world(pid).conversation == nil
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
      assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
      refute_received :pc_literal_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
