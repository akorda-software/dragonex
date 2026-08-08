defmodule Dragones.DMTest do
  @moduledoc "The DM's world brief is deterministic and surfaces exactly what the LLM needs."

  use ExUnit.Case, async: true

  alias Dragones.{Archetypes, Brief, Character, Monsters, World}

  test "exploration brief flags the acting PC and shows the stats" do
    w =
      World.new()
      |> add(World.add_character(Archetypes.fighter()))
      |> add(World.add_character(Monsters.goblin()))

    brief = Brief.world_brief(w, "Thane")

    assert brief =~ "Exploración"
    assert brief =~ "Es el turno de Thane (jugador humano)"
    assert brief =~ "Thane (fighter, pc)"
    assert brief =~ "12/12 pg, CA 16"
    assert brief =~ "Armas: longsword, javelin"
    assert String.contains?(brief, "<- ACTÚA AHORA")
  end

  test "combat brief shows the round, initiative and the DM's monster to act" do
    w =
      World.new()
      |> add(World.add_character(Archetypes.fighter()))
      |> add(World.add_character(Monsters.goblin()))
      |> add(World.begin_combat(["goblin", "Thane"]))

    brief = Brief.world_brief(w, "dm", "dm")

    assert brief =~ "Combate -- ronda 1"
    assert brief =~ "iniciativa: goblin -> Thane"
    assert brief =~ "Es TU turno (DM) -- actúa por: goblin."
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

    brief = Brief.world_brief(w, "Lyra")
    assert brief =~ "0/7 pg"
    assert brief =~ "[CAÍDO]"
  end

  test "a dead character (3 fails) is flagged [MUERTO], not [CAÍDO]" do
    w =
      World.new()
      |> add(World.add_character(Archetypes.wizard()))
      |> add(World.add_character(Monsters.goblin()))

    %Character{} = lyra = w.characters["Lyra"]

    dead = %Character{lyra | hp: 0, death_saves: %{successes: 0, fails: 3}}
    w = %{w | characters: Map.put(w.characters, "Lyra", dead)}

    brief = Brief.world_brief(w, "Lyra")
    assert brief =~ "[MUERTO]"
    refute brief =~ "[CAÍDO]"
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end
end
