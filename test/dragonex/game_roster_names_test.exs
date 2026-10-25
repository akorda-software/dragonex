defmodule Dragonex.GameRosterNamesTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Games}

  # These invalid rosters must fail before any Repo call. No Sandbox checkout
  # is needed, and the returned sheet names are never silently rewritten.
  for {first, second} <- [
        {"Thane", "Thane"},
        {"Thane", " thane "},
        {"Árin", " ÁRIN "}
      ] do
    test "rejects duplicate names #{inspect(first)} and #{inspect(second)} before persistence" do
      first = %{Archetypes.fighter() | name: unquote(first)}
      second = %{Archetypes.wizard() | name: unquote(second)}

      assert {:error, {:name_taken, unquote(second)}} =
               Games.create_game(roster: [{first, :human, 1}, {second, :ai, 2}])
    end
  end

  for name <- ["dm", "DM", " dM "] do
    test "reserves #{inspect(name)} for the DM before persistence" do
      sheet = %{Archetypes.fighter() | name: unquote(name)}
      assert {:error, {:name_taken, unquote(name)}} = Games.create_game(roster: [{sheet, :human}])
    end
  end

  test "duplicate enemies also fail without crashing World construction" do
    enemy = Dragonex.Monsters.goblin()

    assert {:error, {:name_taken, "goblin"}} =
             Games.create_game(roster: [{enemy, :ai}, {enemy, :ai}])
  end
end
