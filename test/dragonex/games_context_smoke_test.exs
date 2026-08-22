defmodule Dragonex.GamesContextSmokeTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Games, Monsters}
  alias Dragonex.Games.{GameEvent, Participant}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
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
    assert %Dragonex.World{phase: :combat} = world
    assert world.initiative_order == ["goblin", "Thane"]
    assert %Dragonex.Character{hp: 12} = world.characters["Thane"]

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

  test "delete_narrations_for_turn drops only that turn's narrations" do
    {:ok, game} =
      Games.create_game(
        title: "scrub",
        scene: "x",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}]
      )

    # Two narrations on turn "AAA" (the partial + the retry) and one on "BBB".
    Games.append_event(game.id, :narration, "dm", "all", %{text: "parcial…", turn_id: "AAA"})
    Games.append_event(game.id, :narration, "dm", "all", %{text: "completa", turn_id: "AAA"})
    Games.append_event(game.id, :narration, "dm", "all", %{text: "otro turno", turn_id: "BBB"})
    # A dice event on "AAA" must be preserved (real outcome).
    Games.append_event(game.id, :dice, "dm", "all", %{turn_id: "AAA", reason: "ataque"})

    {count, _} = Games.delete_narrations_for_turn(game.id, "AAA")

    assert count == 2

    remaining = Games.list_events(game.id)

    refute Enum.any?(remaining, fn e ->
             e.type == :narration and e.payload["turn_id"] == "AAA"
           end)

    assert Enum.any?(remaining, fn e ->
             e.type == :narration and e.payload["turn_id"] == "BBB"
           end)

    assert Enum.any?(remaining, fn e ->
             e.type == :dice and e.payload["turn_id"] == "AAA"
           end)
  end

  test "join_game is idempotent for the same user" do
    {:ok, owner} =
      Dragonex.Accounts.register(%{
        email: "owner#{System.unique_integer([:positive])}@t.test",
        password: "password123",
        display_name: "Owner"
      })

    {:ok, joiner} =
      Dragonex.Accounts.register(%{
        email: "join#{System.unique_integer([:positive])}@t.test",
        password: "password123",
        display_name: "Joiner"
      })

    {:ok, sheet} =
      Dragonex.Heroes.build(%{
        name: "Nara",
        race: "human",
        class: "fighter",
        background: "soldier"
      })

    {:ok, game} =
      Games.create_game(
        title: "open",
        scene: "x",
        user_id: owner.id,
        open_slots: 2,
        roster: [{Archetypes.fighter(), :human}]
      )

    assert {:ok, _} = Games.join_game(game, joiner, sheet)
    assert {:error, :already_joined} = Games.join_game(Games.get_game(game.id), joiner, sheet)
  end
end
