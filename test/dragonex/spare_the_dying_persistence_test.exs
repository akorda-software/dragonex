defmodule Dragonex.SpareTheDyingPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game reload keeps zero HP, stability and spent action; later damage starts fresh failures" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 12,
        max_hp: 12,
        spells: [Spells.to_character_spell(Spells.get("spare the dying"), :wis)]
      )

    a = Character.new(name: "A", hp: 0, max_hp: 20, death_saves: %{successes: 1, fails: 2})

    {:ok, game} =
      Games.create_game(title: "Spare the Dying persistence", roster: [{c, :human}, {a, :human}])

    w = Games.load_world(Games.get_game(game.id))
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, change} = Actions.spell(w, "C", "spare the dying", "A", fn _ -> flunk("no dice") end)
    {:ok, w} = change.(w)
    {:ok, _} = Games.save_state(game.id, w, "C", w.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert loaded.characters["A"].hp == 0
    assert loaded.characters["A"].death_saves == %{successes: 3, fails: 0}
    assert loaded.spell_slots == w.spell_slots
    assert loaded.turn_state["C"]["action"]

    assert {:error, _} =
             Actions.death_save(loaded, "A", fn _ -> flunk("stable needs no save") end)

    :ok = stop_supervised({Game, game.id})
    {:ok, damaged} = World.apply_damage("A", 1, nil, nil, crit: true).(loaded)
    assert damaged.characters["A"].death_saves == %{successes: 0, fails: 2}
    refute World.dead?(damaged, "A")
  end
end
