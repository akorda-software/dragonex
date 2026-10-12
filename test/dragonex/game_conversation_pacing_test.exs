defmodule Dragonex.GameConversationPacingTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @scene "Maribel seca un cuenco mientras la tarde entra por los postigos."
  @question "Lyra, Vex, ¿qué recordáis del combate, y qué puede confirmar la posadera? Espero vuestras respuestas antes de decidir."
  @speech "—Lyra, Vex, ¿qué recordáis del combate, y qué puede confirmar la posadera?"
  @answer "La decisión sigue en manos de Thane."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp observe(parent, stage, response) do
    fn messages, _ ->
      send(parent, {:conversation_pacing, stage, ModelMessages.project(messages)})
      response
    end
  end

  defp boot(model) do
    {:ok, game} =
      Games.create_game(
        title: "Una conversación no exige repetir el ambiente",
        scene: @scene,
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    for _ <- 1..2 do
      assert {:ok, _} = Games.append_event(game.id, :narration, "dm", "all", %{text: @scene})
    end

    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :conversation_pacing_tm)
          "(no decision)"
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model, turnmaster_model: tm)
    state = :sys.get_state(pid)

    for actor <- ["Lyra", "Vex"] do
      assert :ok ==
               Server.set_model(state.pc_agents[actor], %Test{
                 script: [narration("—Recuerdo la flecha."), narration("—Recuerdo el saquito.")]
               })
    end

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before}
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  defp assert_closing_request(wire) do
    prompt =
      wire |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("content")

    assert Enum.any?(
             wire,
             &(&1["role"] == "system" and &1["content"] =~ "Eres el Dungeon Master")
           )

    assert Enum.any?(wire, &ModelMessages.imported?(&1, @speech))
    assert prompt =~ @question
    assert prompt =~ "Una conversación entre PCs no es un atasco"
    assert prompt =~ "No recapitules sus respuestas ni repitas la descripción del ambiente"
    assert prompt =~ "No añadas gestos PNJ, utensilios, sonidos, luces u hora del día"
    assert prompt =~ "El motor devolverá la palabra a Thane"
    assert prompt =~ "si un PNJ también recibió una pregunta"
    assert prompt =~ "No respondas por PCs ni inventes sus gestos"
    refute prompt =~ "Cierra este intercambio en 1-2 frases de ambiente"
    refute prompt =~ "cambia el detalle sensorial"
    refute prompt =~ "lenguaje y un enfoque NUEVOS y vívidos"
    refute prompt =~ "AVANCE OBLIGATORIO"
    refute prompt =~ "Si la escena lleva parada más de un turno, introduce algo NUEVO"
    assert String.valid?(Jason.encode!(wire))
  end

  test "both repeated conversations receive a factual closing request without obligatory scenery" do
    parent = self()

    {game, pid, before} =
      boot(%Test{
        script: [
          observe(parent, :first, narration(@answer)),
          observe(parent, :second, narration(@answer))
        ]
      })

    try do
      for stage <- [:first, :second] do
        if stage == :second do
          assert :ok == Game.resume(pid)
          assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
        end

        assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
        finish(pid)
        assert_receive {:conversation_pacing, ^stage, wire}
        assert_closing_request(wire)
        assert Game.world(pid) == before
        assert Games.load_world(Games.get_game(game.id)) == before
      end

      events = Games.list_events(game.id)

      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) ==
               ["Thane", "Lyra", "Vex", "dm", "Thane", "Lyra", "Vex", "dm"]

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == @answer and
                   &1.payload["complete"] == true)
             ) == 2

      refute Enum.any?(events, &(&1.type == :dice))
      refute_received :conversation_pacing_tm
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restarting the pending DM keeps closing guidance and does not replay companion speech" do
    parent = self()

    pending = fn messages, _ ->
      send(
        parent,
        {:conversation_pacing_pending, self(), ModelMessages.project(messages)}
      )

      receive do: (:finish -> narration(@answer))
    end

    {game, pid, before} = boot(%Test{script: [pending]})

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      assert_receive {:conversation_pacing_pending, run, wire}, 2_000
      assert_closing_request(wire)
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      assert asked.conversation["stage"] == "world"
      assert asked.conversation["pending"] == []
      ref = Process.monitor(run)

      assert {:ok, fresh} =
               Game.restart(game.id,
                 model: %Test{script: [observe(parent, :restarted, narration(@answer))]}
               )

      assert fresh != pid
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked
      assert :ok == Game.resume(fresh)
      finish(fresh)
      assert_receive {:conversation_pacing, :restarted, next_wire}
      assert_closing_request(next_wire)
      assert Game.world(fresh) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      events = Games.list_events(game.id)

      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) ==
               ["Thane", "Lyra", "Vex", "dm", "dm"]

      for actor <- ["Thane", "Lyra", "Vex", "dm"],
          do:
            assert(
              Enum.count(
                events,
                &(&1.type == :narration and &1.actor == actor and &1.payload["complete"] == true)
              ) == 1
            )

      refute Enum.any?(events, &(&1.type == :dice))
      refute_received :conversation_pacing_tm
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a direct NPC question still answers and records its attributed information" do
    parent = self()

    tool =
      tool_calls([
        call("record_npc_statement", %{
          "speaker" => "Maribel",
          "statement" => "Vi salir al forastero."
        })
      ])

    answer = "—Vi salir al forastero —dice Maribel."

    {game, pid, before} =
      boot(%Test{
        script: [
          observe(parent, :npc_tool, tool),
          observe(parent, :npc_answer, narration(answer))
        ]
      })

    try do
      assert {:ok, :resolving} ==
               Game.declare(
                 pid,
                 "Thane",
                 "Le pregunto a la posadera: «¿Qué viste?» Espero su respuesta."
               )

      finish(pid)

      for stage <- [:npc_tool, :npc_answer] do
        assert_receive {:conversation_pacing, ^stage, wire}

        prompt =
          wire |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("content")

        assert prompt =~ "Responde como ese PNJ"
        assert prompt =~ "record_npc_statement"
        refute prompt =~ "Una conversación entre PCs no es un atasco"
      end

      after_answer = Game.world(pid)
      assert length(after_answer.facts) == length(before.facts) + 1
      assert List.last(after_answer.facts) =~ "Maribel"
      assert Map.drop(after_answer, [:facts, :log]) == Map.drop(before, [:facts, :log])
      assert Games.load_world(Games.get_game(game.id)) == after_answer
      events = Games.list_events(game.id)
      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) == ["Thane", "dm"]

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == answer and
                   &1.payload["complete"] == true)
             ) == 1

      refute Enum.any?(events, &(&1.type == :dice))
      refute_received :conversation_pacing_tm
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
