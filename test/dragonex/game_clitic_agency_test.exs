defmodule Dragonex.GameCliticAgencyTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Game, Games, History}
  alias ExAgent.Models.Test

  @sample File.read!(Path.expand("../fixtures/narration/dm_iria_clitic_gesture.txt", __DIR__))
  @human "Iria del Alba"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the real DM closing persists and enters history without moving the human or losing the kitchen" do
    {:ok, game} =
      Games.create_game(
        title: "La jugadora decide su gesto",
        scene: "Una sala tranquila junto al roble.",
        roster: [{Archetypes.fighter(name: @human), :human}, {Archetypes.wizard(), :ai}]
      )

    before = Games.load_world(game)
    model = %Test{script: [narration(@sample <> " #{@human}, ¿qué quieres observar?")]}
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok == Game.await(pid, &(&1.current == @human and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    events = Games.list_events(game.id)

    assert [%{payload: %{"text" => clean}}] =
             Enum.filter(events, fn event ->
               event.type == :narration and
                 String.starts_with?(event.payload["text"], "Las tres respuestas")
             end)

    assert clean =~ "Las tres respuestas se posan"
    assert clean =~ "El calor de la cocina sigue llegando"
    assert clean =~ "¿qué quieres observar?"
    refute clean =~ "Iria las recoge"
    refute clean =~ "asintiendo"
    history = History.from_events(events) |> inspect(limit: :infinity)
    refute history =~ "asintiendo"
    assert history =~ "El calor de la cocina"
    refute Enum.any?(events, &(&1.type == :dice))
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == before
    assert Game.current(reopened) == @human
    assert Game.status(reopened) == :paused
  end
end
