defmodule Dragonex.GameExplorationOpeningTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "after the opening DM, one or five companions cannot act before the first manual decision" do
    for count <- [1, 5] do
      companions = for n <- 1..count, do: {Archetypes.fighter(name: "Compañero #{n}"), :ai}

      {:ok, game} =
        Games.create_game(
          title: "Primera decisión",
          scene: "Una sala tranquila.",
          roster: [{Archetypes.fighter(), :human} | companions]
        )

      before = Games.load_world(game)
      {:ok, _} = Games.save_state(game.id, before, nil, before.round, :paused)
      parent = self()

      tm = %ExAgent.Models.Test{
        script: [
          fn _, _ ->
            send(parent, :unnecessary_opening_tm)
            tool_calls([call("give_turn_to", %{"participant" => "Compañero 1"})])
          end,
          "listo"
        ]
      }

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game,
           {game.id,
            [
              model: %Dragonex.Test.Narrator{text: "La ventana está cerrada."},
              turnmaster_model: tm
            ]}}
        )

      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
      assert :ok == Game.pause(pid)
      refute_received :unnecessary_opening_tm
      turns = Enum.filter(Games.list_events(game.id), &(&1.type == :turn))
      assert Enum.map(turns, & &1.actor) == ["dm"]
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert :ok == stop_supervised({Game, game.id})

      reopened =
        Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %ExAgent.Models.Test{}]}})

      assert Game.current(reopened) == "Thane"
      assert Game.status(reopened) == :paused
      assert Game.world(reopened) == before
      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)
      assert Enum.filter(Games.list_events(game.id), &(&1.type == :turn)) == turns
      assert :ok == stop_supervised({Game, game.id})
    end
  end
end
