defmodule Dragones.GamesContextSmokeTest do
  use ExUnit.Case, async: true

  alias Dragones.{Archetypes, Games, Monsters}
  alias Dragones.Games.{GameEvent, Participant}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    :ok
  end

  test "create_game persists world, participants, characters and events" do
    {:ok, game} =
      Games.create_game(
        title: "smoke",
        scene: "a ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    assert game.world["phase"] == "combat"
    assert game.world["characters"]["Thane"]["hp"] == 12
    assert game.status == :running

    world = Games.load_world(game)
    assert %Dragones.World{phase: :combat} = world
    assert world.initiative_order == ["goblin", "Thane"]
    assert %Dragones.Character{hp: 12} = world.characters["Thane"]

    reloaded = Games.get_game(game.id)
    assert length(reloaded.participants) == 2
    assert Enum.find(reloaded.participants, &(&1.name == "dm")).kind == :ai
    assert Enum.find(reloaded.participants, &(&1.name == "Thane")).kind == :human
    assert length(reloaded.characters) == 2

    events = Games.list_events(game.id)
    assert length(events) == 2
    assert hd(events).type == :system

    {:ok, evt} = Games.append_event(game.id, :narration, "dm", "all", %{text: "hi"})
    assert evt.seq == 3

    {:ok, _} = Games.save_state(game.id, world, "Thane", 2, :waiting)
    assert Games.get_game(game.id).current_participant == "Thane"
    assert Games.get_game(game.id).status == :waiting
  end
end
