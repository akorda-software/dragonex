defmodule Dragonex.GameObservationIntegrityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, History}
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the three complete real observations survive each agent, history and rehydration" do
    replies =
      for {name, file} <- [
            {"Lyra", "pc_lyra_light_hour.txt"},
            {"Mara de la Bruma", "pc_mara_light_jar.txt"},
            {"Nera del Camino", "pc_nera_forest_truth.txt"}
          ],
          do:
            {name,
             File.read!(Path.expand("../fixtures/narration/" <> file, __DIR__)) |> String.trim()}

    human = "Iria del Alba"

    {:ok, game} =
      Games.create_game(
        title: "Observaciones completas",
        scene: "Una sala tranquila.",
        roster: [
          {Archetypes.fighter(name: human), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.wizard(name: "Mara de la Bruma"), :ai},
          {Archetypes.fighter(name: "Nera del Camino"), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, human, before.round, :paused)

    model = %Test{
      script: [
        tool_calls([
          call("request_response", %{
            "recipients" => Enum.map(replies, &elem(&1, 0)),
            "question" => "¿Qué observaríais?"
          })
        ]),
        narration("—¿Qué observaríais desde aquí?"),
        narration("La sala sigue tranquila.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    state = :sys.get_state(pid)

    for {name, reply} <- replies,
        do:
          assert(
            :ok == Server.set_model(state.pc_agents[name], %Test{script: [narration(reply)]})
          )

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == human and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(pid, human, "Escucho vuestras propias observaciones sin moverme.")

    assert :ok == Game.await(pid, &(&1.current == human and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
    events = Games.list_events(game.id)

    for {name, reply} <- replies do
      assert [%{payload: %{"text" => ^reply}}] =
               Enum.filter(events, &(&1.type == :narration and &1.actor == name))

      assert History.from_events(events) |> inspect(limit: :infinity) =~ reply
    end

    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == before
    assert Game.current(reopened) == human
    assert Game.status(reopened) == :paused
  end
end
