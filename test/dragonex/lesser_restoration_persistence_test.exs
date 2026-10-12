defmodule Dragonex.LesserRestorationPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game reload retains selected removal, remaining expiry, slot and spent action" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        level: 3,
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("lesser restoration"), :wis)]
      )

    a = Character.new(name: "A", hp: 5, max_hp: 20)

    {:ok, game} =
      Games.create_game(title: "Restoration persistence", roster: [{c, :human}, {a, :human}])

    w = Games.load_world(Games.get_game(game.id))
    {:ok, w} = World.apply_condition("A", "poisoned", 60).(w)
    {:ok, w} = World.apply_condition("A", "blinded", 120).(w)
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)

    {:ok, _, change} =
      Actions.spell(
        w,
        "C",
        "lesser restoration",
        "A",
        fn _ -> flunk("no dice") end,
        nil,
        nil,
        nil,
        "poisoned"
      )

    {:ok, next} = change.(w)
    {:ok, _} = Games.save_state(game.id, next, "C", next.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert Character.condition_names(loaded.characters["A"]) == ["blinded"]
    assert loaded.characters["A"].hp == 5
    assert loaded.spell_slots == next.spell_slots
    assert loaded.turn_state["C"]["action"]
    assert loaded.effect_expiries["A"]["condition:blinded"] == 120
    refute Map.has_key?(loaded.effect_expiries["A"], "condition:poisoned")
    :ok = stop_supervised({Game, game.id})
  end
end
