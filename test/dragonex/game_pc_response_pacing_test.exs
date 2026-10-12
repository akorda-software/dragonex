defmodule Dragonex.GamePCResponsePacingTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @question "Lyra, Vex, ¿qué recordáis del combate?"
  @answers %{
    "Lyra" => "—Recuerdo el disparo certero; quisiera entender cómo acertaste.",
    "Vex" => "—Una buena posición y algo de suerte."
  }

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp observe(actor) do
    parent = self()

    fn messages, _ ->
      send(parent, {:pc_pacing, actor, ModelMessages.project(messages)})
      narration(@answers[actor])
    end
  end

  defp install(pid) do
    for {actor, server} <- :sys.get_state(pid).pc_agents do
      assert :ok == Server.set_model(server, %Test{script: [observe(actor)]})
    end
  end

  defp boot do
    {:ok, game} =
      Games.create_game(
        title: "Responder sin gestos obligatorios",
        scene: "La taberna sigue en calma.",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    for actor <- ["Lyra", "Vex"], _ <- 1..2 do
      assert {:ok, _} =
               Games.append_event(game.id, :narration, actor, "all", %{
                 text: "Prefiero estudiar el mapa antes de elegir el camino."
               })
    end

    original = Games.list_events(game.id)
    parent = self()

    unexpected = %Test{
      script: [
        fn _, _ ->
          send(parent, :pc_pacing_other)
          "Sin novedad."
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: unexpected, turnmaster_model: unexpected)
    install(pid)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before, original}
  end

  defp assert_request(wire, actor) do
    assert [%{"role" => "system", "content" => role} | _] = wire
    assert role =~ "Eres #{actor},"
    assert role =~ "Responder una pregunta ya es una intervención completa"
    refute role =~ "hay que haber propuesto o hecho un gesto local"

    prompt = wire |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("content")
    assert prompt =~ @question
    assert prompt =~ "Voz de #{actor}"
    assert prompt =~ "ANTIBUCLE DETECTADO"
    assert prompt =~ "Puedes repetir un dato confirmado si vuelve a preguntarse"
    assert prompt =~ "No necesitas añadir un gesto ni proponer una acción"
    assert prompt =~ "No copies sus frases ni sus gestos"
    refute prompt =~ "haz algo DISTINTO y LOCAL"
    refute prompt =~ "ability_check("
    assert String.valid?(Jason.encode!(wire))
  end

  defp finish(game, pid, before, original, turns \\ ["Thane", "Lyra", "Vex"]) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)

    for actor <- ["Lyra", "Vex"] do
      assert_receive {:pc_pacing, ^actor, wire}
      assert_request(wire, actor)

      if actor == "Vex" do
        assert Enum.any?(wire, &ModelMessages.imported?(&1, @answers["Lyra"]))
      end
    end

    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    events = Games.list_events(game.id)
    assert Enum.take(events, length(original)) == original
    new = Enum.drop(events, length(original))

    assert Enum.map(Enum.filter(new, &(&1.type == :narration)), & &1.actor) == [
             "Thane",
             "Lyra",
             "Vex"
           ]

    assert Enum.map(Enum.filter(new, &(&1.type == :turn)), & &1.actor) == turns
    refute Enum.any?(new, &(&1.type == :dice))
    refute_received :pc_pacing_other
  end

  test "both answering PCs receive compatible role and repetition guidance with no extra beat" do
    {game, pid, before, original} = boot()

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(game, pid, before, original)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a pending PC recovers the answer guidance after restart without replaying the human" do
    {game, pid, before, original} = boot()
    parent = self()

    pending = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:pc_pacing_pending, self(), ModelMessages.project(messages)})
          receive do: (:finish -> narration(@answers["Lyra"]))
        end
      ]
    }

    try do
      assert :ok == Server.set_model(:sys.get_state(pid).pc_agents["Lyra"], pending)
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      assert_receive {:pc_pacing_pending, run, wire}, 2_000
      assert_request(wire, "Lyra")
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      ref = Process.monitor(run)
      assert {:ok, fresh} = Game.restart(game.id, model: %Test{label: "Sin novedad."})
      assert fresh != pid
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked
      install(fresh)
      assert :ok == Game.resume(fresh)
      finish(game, fresh, before, original, ["Thane", "Lyra", "Lyra", "Vex"])
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
