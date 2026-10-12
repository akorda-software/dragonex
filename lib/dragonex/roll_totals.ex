defmodule Dragonex.RollTotals do
  @moduledoc "Shared subtotal handling for the timeline, dice cards and agent history."
  use Gettext, backend: Dragonex.Gettext

  @doc "The applied modifier, before a recorded damage minimum."
  def modifier(entry, dice_sum) do
    total = entry[:total] || entry["total"]
    subtotal = clipped_subtotal(entry) || total
    if is_number(subtotal), do: subtotal - dice_sum
  end

  @doc "Explain a damage minimum only when the original subtotal was recorded."
  def minimum_note(entry) do
    if clipped_subtotal(entry), do: dgettext("engine", "(mínimo 0)"), else: ""
  end

  defp clipped_subtotal(entry) do
    kind = entry[:kind] || entry["kind"]
    total = entry[:total] || entry["total"]
    raw = entry[:raw_total] || entry["raw_total"]

    if kind in [:damage, "damage"] and total == 0 and is_number(raw) and raw < 0,
      do: raw
  end
end
