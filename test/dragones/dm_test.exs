defmodule Dragones.DMTest do
  @moduledoc "The DM's world brief is deterministic and surfaces exactly what the LLM needs."

  use ExUnit.Case, async: true

  alias Dragones.{Archetypes, Character, DM, Monsters, World}

  test "exploration brief flags the acting PC and shows the stats" do
    w =
      World.new()
      |> add(World.add_character(Archetypes.fighter()))
      |> add(World.add_character(Monsters.goblin()))

    brief = DM.world_brief(w, "Thane")

    assert brief =~ "Exploration"
    assert brief =~ "It's Thane's turn (player)"
    assert brief =~ "Thane (fighter, pc)"
    assert brief =~ "12/12 hp, AC 16"
    assert brief =~ "Weapons: longsword, javelin"
    assert String.contains?(brief, "<- ACTS NOW")
  end

  test "combat brief shows the round, initiative and the DM's monster to act" do
    w =
      World.new()
      |> add(World.add_character(Archetypes.fighter()))
      |> add(World.add_character(Monsters.goblin()))
      |> add(World.begin_combat(["goblin", "Thane"]))

    brief = DM.world_brief(w, "dm", "dm")

    assert brief =~ "Combat -- round 1"
    assert brief =~ "initiative: goblin -> Thane"
    assert brief =~ "It's YOUR turn (DM) -- act for: goblin."
    assert brief =~ "goblin (monster, enemy)"
  end

  test "a downed character is flagged [DOWN]" do
    w =
      World.new()
      |> add(World.add_character(Archetypes.wizard()))
      |> add(World.add_character(Monsters.goblin()))

    %Character{} = lyra = w.characters["Lyra"]
    down = %Character{lyra | hp: 0}
    w = %{w | characters: Map.put(w.characters, "Lyra", down)}

    brief = DM.world_brief(w, "Lyra")
    assert brief =~ "0/7 hp"
    assert brief =~ "[DOWN]"
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end
end
