defmodule Dragonex.ShieldOfFaithPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Effects
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game rehydrates protected target and remaining duration without modifying the stored base AC" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("shield of faith"), :wis)]
      )

    a = Character.new(name: "A", hp: 10, max_hp: 10, ac: 16)

    {:ok, game} =
      Games.create_game(title: "Faith persistence", roster: [{c, :human}, {a, :human}])

    w = Games.load_world(Games.get_game(game.id))
    {:ok, _, change} = Actions.spell(w, "C", "shield of faith", "A", fn _ -> flunk("no dice") end)
    {:ok, w} = change.(w)
    {:ok, w} = World.advance_time(599).(w)
    {:ok, _} = Games.save_state(game.id, w, "C", w.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert loaded.characters["A"].ac == 16
    assert Effects.effective_ac(loaded.characters["A"]) == 18
    assert loaded.elapsed_seconds == 599
    assert loaded.effect_expiries["C"]["concentrating"] == 600
    assert loaded.spell_slots == w.spell_slots
    :ok = stop_supervised({Game, game.id})
    {:ok, expired} = World.advance_time(1).(loaded)
    assert Effects.effective_ac(expired.characters["A"]) == 16
    assert expired.characters["C"].concentrating == nil
  end
end
