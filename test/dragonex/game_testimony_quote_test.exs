defmodule Dragonex.GameTestimonyQuoteTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games}
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  @claim "Ese hilo es del mismo gris apagado del abrigo, pero no puedo jurar que sea la misma lana."
  @fact "El zagal afirma: «''#{@claim}''» [Registrado a los 37935 s del reloj del mundo.]"
  @question "Le pregunto al zagal: «¿Qué parte es solo una suposición sobre la lana?» Espero aquí su respuesta."
  @speech "El zagal responde: —Sigue siendo una suposición; no puedo jurarlo."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp fixture(facts \\ ["El hilo está en el inventario.", @fact]) do
    {:ok, game} =
      Games.create_game(
        title: "Repetir no renueva el testimonio",
        scene: "El cruce del molino.",
        roster: [{Archetypes.fighter(), :human}]
      )

    world = %{
      Games.load_world(game)
      | elapsed_seconds: 41_535,
        facts: facts,
        scene_refresh_pending: false
    }

    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    {game, world}
  end

  defp record(text),
    do:
      tool_calls([call("record_npc_statement", %{"speaker" => "El zagal", "statement" => text})])

  defp begin_question(pid) do
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
  end

  defp assert_final(game, pid, before) do
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Codec.decode(Codec.encode(before)) == before
    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :action)) == 1

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == @speech)
           ) == 1

    refute Enum.any?(events, &(&1.type == :dice))
  end

  test "normal DM tools with three equivalent spellings preserve the old fact without physical effects" do
    {game, before} = fixture()
    parent = self()

    unexpected = fn _, _ ->
      send(parent, :unexpected_quote_auxiliary)
      "No debería ejecutarse."
    end

    first_request = fn messages, _ ->
      send(parent, {:quote_dm_wire, ModelMessages.project(messages)})
      record("“#{@claim}”")
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{
          script: [first_request, record("«#{@claim}»"), record(@claim), narration(@speech)]
        },
        scene_model: %Test{script: [unexpected]},
        turnmaster_model: %Test{script: [unexpected]}
      )

    try do
      begin_question(pid)
      finish(pid)
      assert_receive {:quote_dm_wire, wire}

      assert List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"] =~
               "este es TU turno DM"

      assert_final(game, pid, before)
      refute_received :unexpected_quote_auxiliary
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart replays the successful wrapped tool and a new unwrapped repeat retains its old reference" do
    {game, before} = fixture(["El hilo está en el inventario."])
    first = "El zagal afirma: «#{@claim}» [Registrado a los 41535 s del reloj del mundo.]"
    expected = %{before | facts: before.facts ++ [first]}
    parent = self()
    wrapped = record("«#{@claim}»")

    blocked = fn _, _ ->
      send(parent, {:quote_saved, self()})
      receive do: (:finish -> narration(@speech))
    end

    {:ok, pid} = Game.ensure_started(game.id, model: %Test{script: [wrapped, blocked]})

    try do
      begin_question(pid)
      assert_receive {:quote_saved, request}, 2_000
      paid = Game.world(pid)
      assert paid.facts == expected.facts
      assert paid.characters == before.characters
      assert paid.actor_checkpoint != nil
      assert Games.load_world(Games.get_game(game.id)) == paid
      assert :ok == Game.pause(pid)
      ref = Process.monitor(request)

      repeat = fn messages, _ ->
        send(parent, {:quoted_replay_wire, ModelMessages.project(messages)})
        record(@claim)
      end

      assert {:ok, fresh} =
               Game.restart(game.id, model: %Test{script: [wrapped, repeat, narration(@speech)]})

      assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
      assert Game.world(fresh) == paid
      assert :ok == Game.resume(fresh)
      finish(fresh)
      assert_receive {:quoted_replay_wire, wire}
      assert inspect(wire, limit: :infinity) =~ "Resultado ya aplicado antes del fallo"
      assert_final(game, fresh, expected)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
