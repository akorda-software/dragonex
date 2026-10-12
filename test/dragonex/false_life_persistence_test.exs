defmodule Dragonex.FalseLifePersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game reload preserves scaled temporary HP and original one-hour deadline" do
    c =
      Character.new(
        name: "C",
        class: "wizard",
        level: 3,
        hp: 5,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
      )

    {:ok, game} = Games.create_game(title: "False Life persistence", roster: [{c, :human}])
    w = Games.load_world(Games.get_game(game.id))
    {:ok, _, change} = Actions.spell(w, "C", "false life", "C", fn 4 -> 3 end, nil, 2)
    {:ok, w} = change.(w)
    {:ok, w} = World.advance_time(3599).(w)
    {:ok, _} = Games.save_state(game.id, w, "C", w.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert loaded.characters["C"].temp_hp == 12
    assert loaded.characters["C"].hp == 5
    assert loaded.spell_slots == w.spell_slots
    assert loaded.elapsed_seconds == 3599
    assert loaded.effect_expiries["C"]["temp_hp"] == 3600
    :ok = stop_supervised({Game, game.id})
    {:ok, expired} = World.advance_time(1).(loaded)
    assert expired.characters["C"].temp_hp == 0
    assert expired.characters["C"].hp == 5
  end
end
