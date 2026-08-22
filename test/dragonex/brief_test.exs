defmodule Dragonex.BriefTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Brief, Monsters, World}

  defp party_world do
    World.new()
    |> then(fn w -> elem(World.add_character(Archetypes.fighter()).(w), 1) end)
    |> then(fn w -> elem(World.add_character(Archetypes.wizard()).(w), 1) end)
    |> then(fn w -> elem(World.add_character(Monsters.goblin()).(w), 1) end)
  end

  test "turnmaster_brief omits the intents block when empty" do
    brief = Brief.turnmaster_brief(party_world(), "dm", ["dm", "Thane", "Lyra"], %{})
    refute brief =~ "Intenciones humanas"
  end

  test "turnmaster_brief lists scrubbed pending human intents" do
    brief =
      Brief.turnmaster_brief(party_world(), "Thane", ["dm", "Thane", "Lyra"], %{
        "Lyra" => "me pongo delante del golpe"
      })

    assert brief =~ "Intenciones humanas pendientes:"
    assert brief =~ "Lyra"
    assert brief =~ "me pongo delante del golpe"
    refute brief =~ "Thane: «"
  end

  test "turnmaster_brief drops blank intents and truncates long ones" do
    long = String.duplicate("x", 250)

    brief =
      Brief.turnmaster_brief(party_world(), nil, ["Lyra"], %{
        "Lyra" => long,
        "Thane" => "   "
      })

    assert brief =~ "Lyra"
    assert brief =~ "…"
    refute brief =~ String.duplicate("x", 250)
    refute brief =~ "Thane: «"
  end
end
