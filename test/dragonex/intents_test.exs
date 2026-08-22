defmodule Dragonex.IntentsTest do
  use ExUnit.Case, async: true

  alias Dragonex.Intents

  test "put encodes text with phase; text/1 reads legacy strings" do
    intents = Intents.put(%{}, "Thane", "abro la puerta", :exploration)
    assert Intents.text(intents["Thane"]) == "abro la puerta"
    assert Intents.phase(intents["Thane"]) == :exploration
    assert Intents.text("ya en cola") == "ya en cola"
    refute Intents.present?(%{"text" => "  "})
    refute Intents.present?(nil)
  end

  test "combat intents go stale only after leaving combat" do
    raw = Intents.encode("interrumpo con Escudo", :combat)
    assert Intents.stale?(raw, :exploration)
    refute Intents.stale?(raw, :combat)

    explore = Intents.encode("ataco al goblin", :exploration)
    refute Intents.stale?(explore, :combat)
    refute Intents.stale?("legacy", :exploration)
  end

  test "reaction?/1 spots interrupt language and ignores exploration plans" do
    assert Intents.reaction?("Interrumpo y me pongo delante de Lyra.")
    assert Intents.reaction?("lanzo Escudo")
    refute Intents.reaction?("abro la puerta")
    refute Intents.reaction?("salgo al camino norte")
  end

  test "drop_stale/2 keeps exploration plans and drops combat leftovers" do
    intents = %{
      "Thane" => Intents.encode("interrumpo", :combat),
      "Lyra" => Intents.encode("miro el sello", :exploration)
    }

    {kept, dropped} = Intents.drop_stale(intents, :exploration)
    assert dropped == ["Thane"]
    assert Map.has_key?(kept, "Lyra")
    refute Map.has_key?(kept, "Thane")
  end

  test "display/1 flattens to text for the UI" do
    intents = Intents.put(%{}, "Thane", "vigilo la luz", :exploration)
    assert Intents.display(intents) == %{"Thane" => "vigilo la luz"}
  end
end
