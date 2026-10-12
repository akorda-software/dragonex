defmodule Dragonex.LayOnHandsPurifyPersistenceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "Game reload preserves pool, spent action and remaining condition deadline" do
    c =
      Character.new(
        name: "C",
        class: "paladin",
        level: 4,
        hp: 20,
        max_hp: 20,
        lay_on_hands_pool: 20
      )

    t = Character.new(name: "T", hp: 5, max_hp: 20)

    {:ok, game} =
      Games.create_game(title: "Hands purification", roster: [{c, :human}, {t, :human}])

    w = Games.load_world(Games.get_game(game.id))
    {:ok, w} = World.apply_condition("T", "poisoned", 60).(w)
    {:ok, w} = World.apply_condition("T", "diseased", 120).(w)
    {:ok, w} = World.begin_combat(["C", "T"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {:ok, _, change} = Actions.lay_on_hands(w, "C", "T", 0, ["poisoned"])
    {:ok, next} = change.(w)
    {:ok, _} = Games.save_state(game.id, next, "C", next.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert loaded.characters["C"].lay_on_hands_pool == 15
    assert loaded.characters["T"].hp == 5
    assert Character.condition_names(loaded.characters["T"]) == ["diseased"]
    assert loaded.effect_expiries["T"] == %{"condition:diseased" => 120}
    assert loaded.turn_state["C"]["action"]
    :ok = stop_supervised({Game, game.id})
  end
end
