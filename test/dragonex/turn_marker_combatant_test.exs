defmodule Dragonex.TurnMarkerCombatantTest do
  use ExUnit.Case, async: false
  alias Dragonex.{Archetypes, Games}
  alias Dragonex.Game.Beats

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    {:ok, game} = Games.create_game(title: "Marcas", roster: [{Archetypes.fighter(), :human}])
    %{game: game, world: Games.load_world(game)}
  end

  defp marker(game, actor, turn_id, world) do
    _ = Beats.append_turn_marker(game.id, actor, turn_id, world)
    game.id |> Games.list_events() |> Enum.find(&(&1.payload["turn_id"] == turn_id))
  end

  test "a DM combat turn marker names the acting creature", %{game: game, world: world} do
    combat = %{world | phase: :combat, current_combatant: "goblin2"}
    assert marker(game, "dm", "a1", combat).payload["combatant"] == "goblin2"

    refute Map.has_key?(marker(game, "Thane", "a2", combat).payload, "combatant")
    refute Map.has_key?(marker(game, "dm", "a3", world).payload, "combatant")
  end
end
