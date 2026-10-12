defmodule Dragonex.HeroesValidationTest do
  @moduledoc """
  The builder rejects illegal 5e choices: unknown races/classes/backgrounds,
  scores out of range, wrong skill count, skills not on the class list.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Heroes

  describe "unknown selections are rejected" do
    test "unknown race" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "titan",
                 class: "fighter",
                 background: "soldier"
               })

      assert msg =~ "raza desconocida"
    end

    test "race requires a subrace" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "elf",
                 class: "wizard",
                 background: "sage"
               })

      assert msg =~ "subraza"
    end

    test "invalid subrace" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "elf",
                 subrace: "space elf",
                 class: "wizard",
                 background: "sage"
               })

      assert msg =~ "subraza"
    end

    test "unknown class" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "necromancer",
                 background: "sage"
               })

      assert msg =~ "clase desconocida"
    end

    test "unknown background" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "astronaut"
               })

      assert msg =~ "unknown background"
    end

    test "missing name" do
      attrs = %{race: "human", class: "fighter", background: "soldier"}
      # name is nil → changeset requires it
      result = Heroes.build(attrs)
      assert match?({:error, _}, result)
    end
  end

  describe "illegal ability scores are rejected" do
    test "score below 1 after racial bonus is impossible (but pre-racial 8 is fine)" do
      # Standard human: min score 8+1=9, always valid. Let's test explicit out-of-range.
      assert {:error, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "fighter",
                 background: "soldier",
                 scores: %{str: 0, dex: 10, con: 10, int: 10, wis: 10, cha: 10}
               })
    end

    test "point buy score above 15 is rejected" do
      assert {:error, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "fighter",
                 background: "soldier",
                 scores: %{
                   method: :point_buy,
                   scores: %{str: 16, dex: 8, con: 8, int: 8, wis: 8, cha: 8}
                 }
               })
    end

    test "standard array must be exactly [15,14,13,12,10,8]" do
      assert {:error, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "fighter",
                 background: "soldier",
                 scores: %{method: :standard_array, values: [18, 14, 13, 12, 10, 8]}
               })
    end

    test "missing ability in explicit scores" do
      assert {:error, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "fighter",
                 background: "soldier",
                 scores: %{str: 10, dex: 10, con: 10, int: 10, wis: 10}
               })
    end
  end

  describe "illegal skills are rejected" do
    test "too many skills" do
      assert {:error, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 # wizard gets 2
                 skills: ["arcana", "history", "insight"]
               })
    end

    test "skill not on the class list" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 # athletics not on wizard list
                 skills: ["arcana", "athletics"]
               })

      assert msg =~ "fuera de la lista de la clase"
    end

    test "empty skills list uses class defaults" do
      assert {:ok, c} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 skills: []
               })

      assert length(c.skill_proficiencies) >= 2
    end

    test "correct skills are accepted" do
      assert {:ok, _} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 skills: ["arcana", "investigation"]
               })
    end
  end

  describe "illegal spells are rejected" do
    test "too many cantrips" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 spells: ["fire bolt", "light", "mage hand", "ray of frost"]
               })

      assert msg =~ "trucos"
    end

    test "spell not on the class list" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 spells: ["cure wounds"]
               })

      assert msg =~ "fuera de la lista de la clase"
    end

    test "unknown spell name" do
      assert {:error, msg} =
               Heroes.build(%{
                 name: "X",
                 race: "human",
                 class: "wizard",
                 background: "sage",
                 spells: ["banana blast"]
               })

      assert msg =~ "hechizos desconocidos"
    end
  end
end
