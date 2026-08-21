defmodule Dragonex.SpellSlots do
  @moduledoc """
  SRD 5.1 spell-slot progression.

  Full casters (bard, cleric, druid, sorcerer, warlock, wizard) get slots from
  level 1. Half casters (paladin, ranger) start at level 2. Non-casters get no
  slots.

  Warlock slots are simplified to the full-caster table (they differ in 5e —
  warlock slots are all the same level and return on a short rest — but the
  distinction is minor at low levels and the simplification keeps the engine
  clean).

  ## Table (full casters)

  ```
  Lvl | 1st  2nd  3rd  4th  5th  6th  7th  8th  9th
  ----+---------------------------------------------
    1 |   2    —    —    —    —    —    —    —    —
    2 |   3    —    —    —    —    —    —    —    —
    3 |   4    2    —    —    —    —    —    —    —
    4 |   4    3    —    —    —    —    —    —    —
    5 |   4    3    2    —    —    —    —    —    —
  ```
  """

  @full_caster %{
    1 => %{1 => 2},
    2 => %{1 => 3},
    3 => %{1 => 4, 2 => 2},
    4 => %{1 => 4, 2 => 3},
    5 => %{1 => 4, 2 => 3, 3 => 2},
    6 => %{1 => 4, 2 => 3, 3 => 3},
    7 => %{1 => 4, 2 => 3, 3 => 3, 4 => 1},
    8 => %{1 => 4, 2 => 3, 3 => 3, 4 => 2},
    9 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 1},
    10 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2},
    11 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1},
    12 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1},
    13 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1, 7 => 1},
    14 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1, 7 => 1},
    15 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1, 7 => 1, 8 => 1},
    16 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1, 7 => 1, 8 => 1},
    17 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2, 6 => 1, 7 => 1, 8 => 1, 9 => 1},
    18 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 3, 6 => 1, 7 => 1, 8 => 1, 9 => 1},
    19 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 3, 6 => 2, 7 => 1, 8 => 1, 9 => 1},
    20 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 3, 6 => 2, 7 => 2, 8 => 1, 9 => 1}
  }

  @half_caster %{
    1 => %{},
    2 => %{1 => 2},
    3 => %{1 => 3},
    4 => %{1 => 3},
    5 => %{1 => 4, 2 => 2},
    6 => %{1 => 4, 2 => 2},
    7 => %{1 => 4, 2 => 3},
    8 => %{1 => 4, 2 => 3},
    9 => %{1 => 4, 2 => 3, 3 => 2},
    10 => %{1 => 4, 2 => 3, 3 => 2},
    11 => %{1 => 4, 2 => 3, 3 => 3},
    12 => %{1 => 4, 2 => 3, 3 => 3},
    13 => %{1 => 4, 2 => 3, 3 => 3, 4 => 1},
    14 => %{1 => 4, 2 => 3, 3 => 3, 4 => 1},
    15 => %{1 => 4, 2 => 3, 3 => 3, 4 => 2},
    16 => %{1 => 4, 2 => 3, 3 => 3, 4 => 2},
    17 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 1},
    18 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 1},
    19 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2},
    20 => %{1 => 4, 2 => 3, 3 => 3, 4 => 3, 5 => 2}
  }

  @full_casters ~w(bard cleric druid sorcerer warlock wizard)
  @half_casters ~w(paladin ranger)

  @doc "The slot map for a class at a given level: `%{slot_level => count}`."
  @spec for_class(String.t(), pos_integer()) :: %{pos_integer() => non_neg_integer()}
  def for_class(class, level) when is_integer(level) and level >= 1 do
    cond do
      class in @full_casters -> Map.get(@full_caster, level, %{})
      class in @half_casters -> Map.get(@half_caster, level, %{})
      true -> %{}
    end
  end

  @doc "Whether a class is any kind of caster."
  @spec caster?(String.t()) :: boolean()
  def caster?(class), do: class in @full_casters or class in @half_casters

  @doc "Whether a class is a full caster (slots from level 1)."
  @spec full_caster?(String.t()) :: boolean()
  def full_caster?(class), do: class in @full_casters
end
