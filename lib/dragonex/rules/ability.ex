defmodule Dragonex.Rules.Ability do
  @moduledoc """
  Pure 5e ability-score math. No state, no IO.

    * Ability modifier: floor((score - 10) / 2).
    * Proficiency bonus: +2 at levels 1-4, +1 every four levels, capped at +6.
  """

  @scores [:str, :dex, :con, :int, :wis, :cha]

  @spec scores() :: [:str | :dex | :con | :int | :wis | :cha]
  def scores, do: @scores

  @doc "Modifier for a score, e.g. 16 -> +3, 8 -> -1, 9 -> -1 (floors down)."
  @spec modifier(integer()) :: integer()
  def modifier(score) when is_integer(score) do
    score
    |> Kernel.-(10)
    |> Kernel./(2)
    |> Float.floor()
    |> trunc()
  end

  @doc "Proficiency bonus for the given character level (1..20)."
  @spec proficiency(pos_integer()) :: pos_integer()
  def proficiency(level) when is_integer(level) and level >= 1 do
    2 + div(level - 1, 4)
  end
end
