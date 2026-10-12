defmodule Dragonex.HealSpellPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game reload preserves healed HP, removed conditions, spent slot and action" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        level: 11,
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("heal"), :wis)]
      )

    a = Character.new(name: "A", hp: 1, max_hp: 100)
    {:ok, game} = Games.create_game(title: "Heal persistence", roster: [{c, :human}, {a, :human}])
    w = Games.load_world(Games.get_game(game.id))
    {:ok, w} = World.apply_condition("A", "blinded", 60).(w)
    {:ok, w} = World.apply_condition("A", "poisoned", 120).(w)
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, change} = Actions.spell(w, "C", "heal", "A", fn _ -> flunk("no dice") end)
    {:ok, w} = change.(w)
    {:ok, _} = Games.save_state(game.id, w, "C", w.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert loaded.characters["A"].hp == 71
    assert Character.condition_names(loaded.characters["A"]) == ["poisoned"]
    assert loaded.effect_expiries["A"] == %{"condition:poisoned" => 120}
    assert loaded.spell_slots["C"][6] == 0
    assert loaded.turn_state["C"]["action"]
    assert {:error, _} = Actions.spell(loaded, "C", "heal", "A", fn _ -> flunk("no dice") end)
  end
end
