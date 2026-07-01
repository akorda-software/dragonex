defmodule DragonesWeb.GameLive.RollFormat do
  @moduledoc """
  Pure presentation formatters for dice-roll entries and outcomes.

  Shared by the chat timeline (`format_line/1`) and the dice modal
  (`format_dice/1`, `format_against_spaced/1`). Extracted from
  `DragonesWeb.GameLive.Show` so the formatting rules live in one place — the
  inline chat line and the modal card each carried their own near-identical copy
  of the dice/mod/total assembly, and the outcome lookup was duplicated across
  three 16-case tables (atom + string arms).
  """

  # outcome -> {inline_chat_marker, modal_label, css_class}
  @outcomes %{
    hit: {"→ ¡ACIERTO!", "¡Acierto!", "dg-win"},
    crit: {"→ ¡CRÍTICO!", "¡Crítico!", "dg-win"},
    miss: {"→ fallo", "Fallo", "dg-lose"},
    success: {"→ éxito", "Éxito", "dg-win"},
    failure: {"→ fallo", "Fallo", "dg-lose"},
    revive: {"→ ¡revive!", "¡Revive!", "dg-win"},
    crit_fail: {"→ ¡PIFIA!", "¡Pifia! (2 fallos)", "dg-lose"}
  }

  @doc "Normalize an outcome value (atom or string) to its atom key, or nil."
  @spec normalize_outcome(term()) :: atom() | nil
  def normalize_outcome(o) when is_atom(o), do: o
  def normalize_outcome(o) when is_binary(o), do: String.to_atom(o)
  def normalize_outcome(_), do: nil

  defp outcome_tuple(o) do
    case Map.get(@outcomes, normalize_outcome(o)) do
      nil -> {"", "", "dg-neutral"}
      tuple -> tuple
    end
  end

  @doc "Inline outcome marker for the chat line, e.g. \"→ ¡ACIERTO!\"."
  @spec outcome_line(term()) :: String.t()
  def outcome_line(o), do: outcome_tuple(o) |> elem(0)

  @doc "Standalone label for the dice modal card, e.g. \"¡Acierto!\"."
  @spec outcome_label(term()) :: String.t()
  def outcome_label(o), do: outcome_tuple(o) |> elem(1)

  @doc "CSS class bucket for the dice card: dg-win | dg-lose | dg-neutral."
  @spec outcome_css(term()) :: String.t()
  def outcome_css(o), do: outcome_tuple(o) |> elem(2)

  # ----------------------------------------------------------------- against

  defp against_kind_n(v) do
    case v do
      ["ac", n] -> {n, "CA"}
      ["dc", n] -> {n, "DC"}
      {:ac, n} -> {n, "CA"}
      {:dc, n} -> {n, "DC"}
      _ -> nil
    end
  end

  @doc "Compact \"vs CA n\" for the chat line (no leading space)."
  @spec format_against(term()) :: String.t()
  def format_against(v) do
    case against_kind_n(v) do
      {n, kind} -> "vs #{kind} #{n}"
      nil -> ""
    end
  end

  @doc "\" vs CA n\" for the dice modal (leading space)."
  @spec format_against_spaced(term()) :: String.t()
  def format_against_spaced(v) do
    case against_kind_n(v) do
      {n, kind} -> " vs #{kind} #{n}"
      nil -> ""
    end
  end

  # --------------------------------------------------------------------- dice

  @doc """
  The inline chat line for a roll entry:
  `<reason>: d20:14 +3 = 17 vs CA 15 → ¡ACIERTO!`.
  """
  @spec format_line(map()) :: String.t()
  def format_line(%{} = p) do
    dice = p["dice"] || p[:dice] || []
    reason = p["reason"] || p[:reason] || "tirada"
    total = p["total"] || p[:total]

    {dice_str, dice_sum} = dice_parts(dice)
    mod = if is_number(total), do: total - dice_sum, else: nil

    parts = [reason, dice_str]

    parts =
      case mod do
        n when is_number(n) and n > 0 -> parts ++ ["+#{n}"]
        n when is_number(n) and n < 0 -> parts ++ ["#{n}"]
        _ -> parts
      end

    parts = if is_number(total), do: parts ++ ["= #{total}"], else: parts
    parts = append_if(parts, format_against(p["against"] || p[:against]))
    parts = append_if(parts, outcome_line(p["outcome"] || p[:outcome]))

    parts |> Enum.reject(&(&1 in ["", nil])) |> Enum.join(" ")
  end

  @doc """
  The dice summary for a modal card: `d20:14 +3 = 17` (no reason, no outcome).
  """
  @spec format_dice(map()) :: String.t()
  def format_dice(%{} = g) do
    dice = g[:dice] || g["dice"] || []
    total = g[:total] || g["total"]

    {dice_str, dice_sum} = dice_parts(dice)
    mod = if is_number(total), do: total - dice_sum, else: nil

    mod_str =
      cond do
        mod == nil -> ""
        mod > 0 -> " +#{mod}"
        mod < 0 -> " #{mod}"
        true -> ""
      end

    total_str = if is_number(total), do: " = #{total}", else: ""

    "#{dice_str}#{mod_str}#{total_str}"
  end

  # Shared parse of a dice list -> {"d20:14 d8:4", sum_of_values}.
  # The string form keeps every `[s,v]`/`{s,v}` pair (even non-numeric v); the
  # sum only adds numeric values (matches the original twin formatters).
  defp dice_parts(dice) do
    Enum.reduce(dice, {"", 0}, fn
      [s, v], {str, sum} ->
        next = if str == "", do: "d#{s}:#{v}", else: "#{str} d#{s}:#{v}"
        add = if is_number(v), do: v, else: 0
        {next, sum + add}

      {s, v}, {str, sum} ->
        next = if str == "", do: "d#{s}:#{v}", else: "#{str} d#{s}:#{v}"
        add = if is_number(v), do: v, else: 0
        {next, sum + add}

      _, acc ->
        acc
    end)
  end

  defp append_if(parts, ""), do: parts
  defp append_if(parts, frag), do: parts ++ [frag]
end
