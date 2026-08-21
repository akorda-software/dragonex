defmodule Dragonex.ArchetypesTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Character, Rules.Combat, Spell, Weapon}

  describe "fighter/1" do
    test "has the canonical level-1 melee stats" do
      f = Archetypes.fighter()
      assert f.class == "fighter"
      assert f.level == 1
      assert f.str == 16
      assert f.hp == 12 and f.max_hp == 12
      assert f.ac == 16
      assert [%Weapon{name: "longsword"}, %Weapon{name: "javelin"}] = f.weapons
    end

    test "accepts a custom name and backstory" do
      f = Archetypes.fighter(name: "Bryn", backstory: "ex-mercenary")
      assert f.name == "Bryn"
      assert f.backstory == "ex-mercenary"
    end
  end

  describe "wizard/1" do
    test "casts and exposes a working spell save DC" do
      w = Archetypes.wizard()
      assert w.class == "wizard"
      firebolt = Enum.find(w.spells, &(&1.name == "firebolt"))
      assert %Spell{} = firebolt
      assert Combat.spell_save_dc(w, firebolt) == 13
    end
  end

  describe "rogue/1" do
    test "wields a finesse weapon" do
      r = Archetypes.rogue()
      shortsword = Enum.find(r.weapons, &(&1.name == "shortsword"))
      assert shortsword.finesse
    end
  end

  describe "every archetype" do
    test "passes the character changeset (bounds stay OutputSchema-valid)" do
      for c <- [Archetypes.fighter(), Archetypes.wizard(), Archetypes.rogue()] do
        attrs =
          c
          |> Map.from_struct()
          |> Enum.reject(fn {k, _} -> k == :__meta__ end)
          |> Map.new()

        changeset = Character.changeset(%Character{}, attrs)
        assert changeset.valid?, explain(changeset)
      end
    end

    test "death-save tracker starts clean" do
      for c <- [Archetypes.fighter(), Archetypes.wizard(), Archetypes.rogue()] do
        assert c.death_saves == %{successes: 0, fails: 0}
      end
    end
  end

  defp explain(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end
end
