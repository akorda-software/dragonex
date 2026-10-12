defmodule Dragonex.BlessPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.{Combat, Effects}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game rehydrates Bless targets and remaining time from Postgres" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("bless"), :wis)]
      )

    a = Character.new(name: "A", hp: 10, max_hp: 10)

    {:ok, game} =
      Games.create_game(title: "Bless persistence", roster: [{c, :human}, {a, :human}])

    w = Games.load_world(Games.get_game(game.id))
    {:ok, _, change} = Actions.spell(w, "C", "bless", "A", fn _ -> flunk("no dice on cast") end)
    {:ok, w} = change.(w)
    {:ok, w} = World.advance_time(45).(w)
    {:ok, _} = Games.save_state(game.id, w, "C", w.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert loaded.elapsed_seconds == 45
    assert loaded.effect_expiries["C"]["concentrating"] == 60
    assert loaded.spell_slots == w.spell_slots
    assert Effects.blessed?(loaded.characters["A"])

    assert {8, 10, true} =
             Combat.saving_throw(loaded.characters["A"], :wis, 10, fn
               20 -> 8
               4 -> 2
             end)

    :ok = stop_supervised({Game, game.id})
    {:ok, expired} = World.advance_time(15).(loaded)
    refute Effects.blessed?(expired.characters["A"])
    assert expired.characters["C"].concentrating == nil
  end
end
