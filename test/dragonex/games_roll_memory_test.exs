defmodule Dragonex.GamesRollMemoryTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Games}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    :ok
  end

  test "older rolls are game-scoped, visibility-filtered before the bound, and chronological" do
    {:ok, game} =
      Games.create_game(title: "Archivo público", roster: [{Archetypes.fighter(), :human}])

    {:ok, other} = Games.create_game(title: "Otra mesa", roster: [{Archetypes.fighter(), :human}])

    for n <- 1..40,
        do:
          Games.append_event(game.id, :dice, "Thane", "all", %{
            reason: "Public#{n}",
            dice: [[20, 10]],
            total: 10
          })

    for n <- 1..40,
        do:
          Games.append_event(game.id, :dice, "dm", "dm", %{
            reason: "Private#{n}",
            dice: [[20, 10]],
            total: 10
          })

    Games.append_event(game.id, :dice, "Lyra", "Lyra", %{reason: "UnsupportedMarker"})
    Games.append_event(other.id, :dice, "Thane", "all", %{reason: "OtherGameMarker"})
    Games.append_event(game.id, :narration, "dm", "all", %{text: "OlderProseMarker"})
    cutoff = Games.next_seq(game.id)
    Games.append_event(game.id, :dice, "Thane", "all", %{reason: "RecentRollMarker"})
    public = Games.rolls_before(game.id, cutoff)
    assert length(public) == 32
    assert Games.rolls_before(game.id, cutoff, nil, 64) == public
    assert Enum.map(public, & &1.payload["reason"]) == Enum.map(9..40, &"Public#{&1}")

    assert Enum.all?(
             public,
             &(&1.game_id == game.id and &1.type == :dice and &1.visible_to == "all" and
                 &1.seq < cutoff)
           )

    dm = Games.rolls_before(game.id, cutoff, "dm")
    assert Enum.map(dm, & &1.payload["reason"]) == Enum.map(9..40, &"Private#{&1}")
    assert Games.rolls_before(game.id, cutoff, "Lyra") == public
    assert Games.rolls_before(game.id, cutoff, "dm", 2) == Enum.take(dm, -2)
  end

  test "dice outside a full recent window remain available without rewriting any stored event" do
    {:ok, game} =
      Games.create_game(title: "Pasado mecánico", roster: [{Archetypes.fighter(), :human}])

    {:ok, attack} =
      Games.append_event(game.id, :dice, "Thane", "all", %{
        reason: "Crítico antiguo",
        dice: [[20, 20]],
        total: 25,
        outcome: "crit"
      })

    for n <- 1..410,
        do:
          Games.append_event(game.id, :system, "system", "all", %{note: "Detalle posterior #{n}"})

    before = Games.list_events(game.id)
    recent = Games.recent_events(game.id, 400)
    refute Enum.any?(recent, &(&1.type == :dice))
    loaded_attack = Enum.find(before, &(&1.id == attack.id))
    assert [loaded_attack] == Games.rolls_before(game.id, hd(recent).seq)
    assert [] == Games.rolls_before(game.id, attack.seq)
    assert Games.list_events(game.id) == before
  end
end
