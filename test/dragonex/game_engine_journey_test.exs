defmodule Dragonex.GameEngineJourneyTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Dragonex.{Actions, Game, Games, Heroes, Monsters, Rest, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "built hero, combat, rest and Game restarts preserve budgets and effect deadlines" do
    {:ok, hero} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, game} =
      Games.create_game(
        title: "engine journey",
        scene: "un campamento junto a las ruinas",
        roster: [{hero, :human}, {Monsters.goblin(), :ai}]
      )

    w = Games.load_world(Games.get_game(game.id))
    {:ok, w} = World.apply_damage("Thane", 6).(w)
    {:ok, w} = World.begin_combat(["Thane", "goblin"]).(w)
    {:ok, w} = World.set_current_combatant("Thane").(w)
    weapon = hd(hero.weapons).name

    # A miss still spends the action. Rehydrating must not refund it.
    {:ok, _, attack} = Actions.attack(w, "Thane", "goblin", weapon, fn _ -> 1 end)
    {:ok, w} = attack.(w)
    {:ok, w} = World.apply_condition("Thane", "poisoned", 7200).(w)
    assert w.turn_state["Thane"]["action"]
    assert w.characters["goblin"].hp == 7

    loaded = restart_from(game.id, w)
    assert loaded.turn_state == w.turn_state
    assert loaded.effect_expiries == w.effect_expiries
    assert loaded.characters["Thane"].hp == hero.hp - 6

    assert {:error, _} =
             Actions.attack(loaded, "Thane", "goblin", weapon, fn _ -> flunk("spent action") end)

    {:ok, w} = World.end_combat().(loaded)
    {:ok, _, rest} = Actions.short_rest(w, "Thane", fn _ -> 1 end)
    {:ok, w} = rest.(w)
    assert w.elapsed_seconds == 3600
    assert Rest.remaining(w, "Thane") == 0
    assert w.characters["Thane"].hp == hero.hp - 6 + 1 + div(hero.con - 10, 2)

    loaded = restart_from(game.id, w)
    assert loaded.rest_state == w.rest_state
    assert loaded.elapsed_seconds == 3600
    assert loaded.effect_expiries["Thane"]["condition:poisoned"] == 7200
    assert Rest.remaining(loaded, "Thane") == 0

    # No dice remain: a second short rest recovers no HP but advances time,
    # expiring the original condition at its original deadline.
    {:ok, _, rest} = Actions.short_rest(loaded, "Thane", fn _ -> flunk("no hit dice") end)
    {:ok, w} = rest.(loaded)
    assert w.characters["Thane"].hp == loaded.characters["Thane"].hp
    refute World.has_condition?(w, "Thane", "poisoned")
    assert w.elapsed_seconds == 7200

    {:ok, _, rest} = Actions.long_rest(w, "Thane")
    {:ok, w} = rest.(w)
    loaded = restart_from(game.id, w)
    assert loaded.characters["Thane"].hp == hero.max_hp
    assert Rest.remaining(loaded, "Thane") == 1
    assert loaded.elapsed_seconds == 36000
    assert {:error, _} = Actions.long_rest(loaded, "Thane")
  end

  # Only seed a stopped game. The real GenServer rehydrates it and persists
  # through its public pause call; no fixture writes race a running Game.
  defp restart_from(id, world) do
    {:ok, _} = Games.save_state(id, world, "Thane", world.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {id, [model: %Test{script: []}]}})
    loaded = Game.world(pid)
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert :ok = Game.pause(pid)
    assert Games.load_world(Games.get_game(id)) == loaded
    :ok = stop_supervised({Game, id})
    loaded
  end
end
