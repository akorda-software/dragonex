defmodule Dragonex.GameScenePresenceTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Monsters, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp roller(20), do: 15
  defp roller(_), do: 1

  defp game do
    {:ok, game} =
      Games.create_game(
        title: "Scene departure and return",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(name: "g1"), :ai}],
        initiative: ["g1", "Thane"]
      )

    world = Games.load_world(Games.get_game(game.id))
    {:ok, world} = World.apply_damage("g1", 4).(world)
    {:ok, _} = Games.save_state(game.id, world, nil, world.round, :running)
    game
  end

  defp departure do
    tool_calls([
      call("leave_scene", %{"who" => "g1", "reason" => "El goblin cruza el puente y se aleja."})
    ])
  end

  defp waiting(pid),
    do: Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)

  test "a real DM departure ends combat and a later return reuses the damaged creature" do
    game = game()

    model = %Test{
      script: [
        departure(),
        narration("Thane, el goblin se aleja por el puente. ¿Qué haces?"),
        narration("Thane vigila el puente."),
        tool_calls([call("return_to_scene", %{"who" => "g1"})]),
        narration("El mismo goblin vuelve al puente."),
        narration("El goblin observa a Thane sin atacar.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: &roller/1]}})
    assert :ok == waiting(pid)
    world = Game.world(pid)
    assert world.phase == :exploration
    assert world.characters["g1"].hp == 3
    assert world.characters["g1"].max_hp == 7
    refute World.present?(world, "g1")
    assert Games.load_world(Games.get_game(game.id)) == world
    assert :ok == Game.pause(pid)

    # Reopen the actual persisted departure before requesting its return.
    assert :ok == stop_supervised({Game, game.id})

    model = %Test{
      script: [
        narration("Thane vigila el puente."),
        tool_calls([call("return_to_scene", %{"who" => "g1"})]),
        narration("El mismo goblin vuelve al puente."),
        narration("El goblin observa a Thane sin atacar.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: &roller/1]}})
    refute World.present?(Game.world(pid), "g1")
    assert :ok == Game.resume(pid)
    assert :ok == waiting(pid)
    assert {:ok, _} = Game.declare(pid, "Thane", "Vigilo el puente.")
    assert :ok == waiting(pid)
    world = Game.world(pid)
    assert world.phase == :combat
    assert World.present?(world, "g1")
    assert world.characters["g1"].hp == 3
    assert world.initiative_order == ["g1", "Thane"]
    assert world.current_combatant == "Thane"
    assert world.acted_this_round == MapSet.new(["g1"])
    assert Games.load_world(Games.get_game(game.id)) == world

    assert Enum.count(
             Games.list_events(game.id),
             &(&1.payload["note"] == "⚔ El combate termina.")
           ) == 1
  end

  test "an actor failure after a committed departure keeps absence and the end of combat" do
    game = game()
    model = %Test{script: [departure(), fn -> raise "failure after committed departure" end]}
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: &roller/1]}})
    assert :ok == waiting(pid)
    world = Game.world(pid)
    assert world.phase == :exploration
    refute World.present?(world, "g1")
    assert world.characters["g1"].hp == 3
    assert Games.load_world(Games.get_game(game.id)) == world

    assert Enum.count(
             Games.list_events(game.id),
             &(&1.payload["note"] == "⚔ El combate termina.")
           ) == 1
  end
end
