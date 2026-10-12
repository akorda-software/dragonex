defmodule Dragonex.ArchetypeGearLabelsTest do
  use ExUnit.Case, async: true
  alias Dragonex.Heroes.Translations

  # 19451's sheet showed «Torch ×4» beside translated gear.
  test "every archetype item has a Spanish label" do
    names =
      for {fun, 0} <- Dragonex.Archetypes.__info__(:functions),
          %Dragonex.Character{inventory: inventory} <- [apply(Dragonex.Archetypes, fun, [])],
          item <- inventory || [],
          uniq: true,
          do: item.name

    assert names != []
    assert Enum.reject(names, &(Translations.item(&1, :es) != String.capitalize(&1))) == []
    assert Translations.item("torch", :es) == "Antorcha"
  end
end
