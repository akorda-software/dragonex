defmodule Dragonex.GameNPCRecipientTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, History}
  alias ExAgent.{Models.Test, Server}

  @sample File.read!(Path.expand("../fixtures/narration/pc_vex_npc_recipient.txt", __DIR__))
          |> String.trim()
  @human "Mara de la Bruma"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "a requested delivery preserves the complete PC response, history and World after rehydration" do
    {:ok, game} =
      Games.create_game(
        title: "El destinatario conserva su nombre",
        scene: "Un patio tranquilo después del encargo.",
        roster: [{Archetypes.wizard(name: @human), :human}, {Archetypes.rogue(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, @human, before.round, :paused)

    model = %Test{
      script: [
        tool_calls([
          call("request_response", %{
            "recipients" => ["Vex"],
            "question" => "¿Puedes devolver el saquito a la posadera?"
          })
        ]),
        narration("—Vex, ¿puedes devolver el saquito a la posadera?"),
        narration("La posadera recibe el saquito.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})

    assert :ok ==
             Server.set_model(:sys.get_state(pid).pc_agents["Vex"], %Test{
               script: [narration(@sample)]
             })

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == @human and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(pid, @human, "Vex, ¿puedes devolver el saquito a la posadera?")

    assert :ok == Game.await(pid, &(&1.current == @human and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
    events = Games.list_events(game.id)

    assert [%{payload: %{"text" => @sample}}] =
             Enum.filter(events, &(&1.type == :narration and &1.actor == "Vex"))

    assert History.from_events(events) |> inspect(limit: :infinity) =~ @sample
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == before
    assert Game.current(reopened) == @human
    assert Game.status(reopened) == :paused
  end
end
