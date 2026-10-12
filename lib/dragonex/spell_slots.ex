defmodule Dragonex.SpellSlots do
  @moduledoc """
  SRD 5.1 spell-slot progression.

  Full casters (bard, cleric, druid, sorcerer, wizard) get slots from level 1.
  Half casters (paladin, ranger) start at level 2. Warlocks use Pact Magic
  (D40): all slots are the same level (1st–5th) and return on a short rest.
  Non-casters get no slots.

  Mystic Arcanum (6th–9th, 1/long rest) is out of v1 — warlock `max_spell_level`
  caps at 5. Damage upcasting (extra magic-missile darts, etc.) is modeled by
  `Dragonex.Rules.Upcast` (D74); the slot spent is still the pact slot.

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

  ## Pact Magic (warlock)

  ```
  Lvl   | slots
  ------+-----------
  1     | 1×1st
  2     | 2×1st
  3–4   | 2×2nd
  5–6   | 2×3rd
  7–8   | 2×4th
  9–10  | 2×5th
  11–16 | 3×5th
  17–20 | 4×5th
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

  @pact_magic %{
    1 => %{1 => 1},
    2 => %{1 => 2},
    3 => %{2 => 2},
    4 => %{2 => 2},
    5 => %{3 => 2},
    6 => %{3 => 2},
    7 => %{4 => 2},
    8 => %{4 => 2},
    9 => %{5 => 2},
    10 => %{5 => 2},
    11 => %{5 => 3},
    12 => %{5 => 3},
    13 => %{5 => 3},
    14 => %{5 => 3},
    15 => %{5 => 3},
    16 => %{5 => 3},
    17 => %{5 => 4},
    18 => %{5 => 4},
    19 => %{5 => 4},
    20 => %{5 => 4}
  }

  @full_casters ~w(bard cleric druid sorcerer wizard)
  @half_casters ~w(paladin ranger)
  @pact_casters ~w(warlock)

  @doc "The slot map for a class at a given level: `%{slot_level => count}`."
  @spec for_class(String.t(), pos_integer()) :: %{pos_integer() => non_neg_integer()}
  def for_class(class, level) when is_integer(level) and level >= 1 do
    cond do
      class in @full_casters -> Map.get(@full_caster, level, %{})
      class in @half_casters -> Map.get(@half_caster, level, %{})
      class in @pact_casters -> Map.get(@pact_magic, level, %{})
      true -> %{}
    end
  end

  @doc """
  Adjust slot capacity after a level-up without restoring prior expenditure.

  Regular casters retain spending per spell level and funded extra slots.
  Pact Magic carries spending across its single pool when the slot level
  changes. `nil` represents an untracked legacy pool; a tracked missing key
  is empty, consistent with `World.has_slot?/3`.
  """
  @spec level_up(String.t(), pos_integer(), pos_integer(), map() | nil) :: map()
  def level_up(class, old_level, new_level, remaining) do
    old_max = for_class(class, old_level)
    new_max = for_class(class, new_level)
    remaining = remaining || old_max

    if pact_caster?(class) do
      spent =
        Enum.reduce(old_max, 0, fn {slot, capacity}, total ->
          total + max(0, capacity - available(remaining, slot))
        end)

      Map.new(new_max, fn {slot, capacity} -> {slot, max(0, capacity - spent)} end)
    else
      (Map.keys(remaining) ++ Map.keys(new_max))
      |> Enum.uniq()
      |> Map.new(fn slot ->
        capacity_gain = Map.get(new_max, slot, 0) - Map.get(old_max, slot, 0)
        {slot, max(0, available(remaining, slot) + capacity_gain)}
      end)
    end
  end

  defp available(slots, level) do
    case Map.get(slots, level, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  @doc "Whether a class is any kind of caster."
  @spec caster?(String.t()) :: boolean()
  def caster?(class),
    do: class in @full_casters or class in @half_casters or class in @pact_casters

  @doc "Whether a class is a full caster (slots from level 1, full-caster table)."
  @spec full_caster?(String.t()) :: boolean()
  def full_caster?(class), do: class in @full_casters

  @doc "Whether a class uses Pact Magic (warlock)."
  @spec pact_caster?(String.t()) :: boolean()
  def pact_caster?(class), do: class in @pact_casters

  @doc """
  Slot key consumed when casting a spell of `spell_level`.

  Warlocks spend one pact slot (the only level they have) if the spell's
  level is > 0 and ≤ that pact level. Other casters spend a slot of
  `spell_level`. Cantrips and over-level warlock spells return `spell_level`.
  """
  @spec slot_level_for(String.t(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  def slot_level_for(class, character_level, spell_level) do
    if pact_caster?(class) and spell_level > 0 do
      pact = pact_slot_level(character_level)
      if spell_level <= pact, do: pact, else: spell_level
    else
      spell_level
    end
  end

  defp pact_slot_level(character_level) do
    case @pact_magic |> Map.get(character_level, %{}) |> Map.keys() do
      [level] -> level
      _ -> 0
    end
  end
end
