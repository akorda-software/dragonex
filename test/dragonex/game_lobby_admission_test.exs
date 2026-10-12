defmodule Dragonex.GameLobbyAdmissionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    owner = user("Anfitrión")
    guest = user("Invitada")
    other = user("Otro jugador")
    %{owner: owner, guest: guest, other: other}
  end

  defp user(name) do
    {:ok, user} =
      Accounts.register(%{
        email: "lobby-admission-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: name
      })

    user
  end

  defp game(owner, slots \\ 1) do
    {:ok, game} =
      Games.create_game(
        title: "La última plaza",
        user_id: owner.id,
        open_slots: slots,
        roster: [{Archetypes.fighter(), :human}]
      )

    game
  end

  test "a stale room snapshot cannot admit a second player after the last slot was taken", ctx do
    stale = game(ctx.owner)
    assert {:ok, _} = Games.join_game(stale, ctx.guest, Archetypes.wizard())
    assert {:error, :no_open_slots} = Games.join_game(stale, ctx.other, Archetypes.rogue())
    current = Games.get_game(stale.id)
    assert current.open_slots == 0
    assert Enum.count(current.participants, &(&1.side == "pc")) == 2
    assert Map.keys(Games.load_world(current).characters) |> Enum.sort() == ["Lyra", "Thane"]
    refute Enum.any?(current.characters, &(&1.name == "Vex"))
  end

  test "two joins using the same snapshot consume two distinct slots and keep both sheets", ctx do
    stale = game(ctx.owner, 2)
    assert {:ok, _} = Games.join_game(stale, ctx.guest, Archetypes.wizard())
    assert {:ok, joined} = Games.join_game(stale, ctx.other, Archetypes.rogue())
    assert joined.open_slots == 0

    assert Map.keys(Games.load_world(joined).characters) |> Enum.sort() == [
             "Lyra",
             "Thane",
             "Vex"
           ]

    assert Enum.count(joined.participants, &(&1.side == "pc")) == 3
  end

  test "a stale configuring snapshot cannot mutate a game that has started", ctx do
    stale = game(ctx.owner)
    assert {:ok, started} = Games.start_game(stale.id)
    before = Games.load_world(started)
    assert {:error, :already_started} = Games.join_game(stale, ctx.guest, Archetypes.wizard())
    after_game = Games.get_game(stale.id)
    assert Games.load_world(after_game) == before
    assert after_game.open_slots == 0
    assert Enum.count(after_game.participants, &(&1.side == "pc")) == 1
  end

  test "a duplicate canonical character name returns an actionable error and rolls back admission",
       ctx do
    game = game(ctx.owner)
    before = Games.load_world(game)
    assert {:error, :name_taken} = Games.join_game(game, ctx.guest, Archetypes.fighter())
    after_game = Games.get_game(game.id)
    assert after_game.open_slots == 1
    assert after_game.characters == game.characters
    assert MapSet.new(after_game.participants) == MapSet.new(game.participants)
    assert Games.load_world(after_game) == before
  end

  test "case variants and the reserved DM name cannot create ambiguous participant identities",
       ctx do
    game = game(ctx.owner)

    for name <- ["THANE", " Thane ", "dm", "DM"] do
      sheet = %{Archetypes.wizard() | name: name}
      assert {:error, :name_taken} = Games.join_game(game, ctx.guest, sheet)
    end

    assert Games.get_game(game.id).open_slots == 1
  end

  test "a repeated join after the last slot preserves the original identity and world", ctx do
    stale = game(ctx.owner)
    assert {:ok, joined} = Games.join_game(stale, ctx.guest, Archetypes.wizard())
    assert {:error, :already_joined} = Games.join_game(stale, ctx.guest, Archetypes.rogue())
    current = Games.get_game(stale.id)
    assert MapSet.new(current.participants) == MapSet.new(joined.participants)
    assert current.characters == joined.characters
    assert Games.load_world(current) == Games.load_world(joined)
  end

  test "a repeated start cannot unpause or reset an already started game", ctx do
    game = game(ctx.owner)
    world = Games.load_world(game)
    intents = %{"Thane" => "Vigilo el puente."}
    assert {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused, intents)
    assert {:ok, current} = Games.start_game(game.id)
    assert current.status == :paused
    assert current.current_participant == "Thane"
    assert current.intents == intents
    assert Games.load_world(current) == world
  end

  test "a deleted room returns typed errors for joining and starting stale snapshots", ctx do
    stale = game(ctx.owner)
    assert {:ok, _} = Games.delete_game(ctx.owner, stale.id)
    assert {:error, :not_found} = Games.join_game(stale, ctx.guest, Archetypes.wizard())
    assert {:error, :not_found} = Games.start_game(stale.id)
  end
end
