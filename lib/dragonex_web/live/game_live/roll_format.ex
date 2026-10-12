defmodule DragonexWeb.GameLive.RollFormat do
  @moduledoc """
  Pure presentation formatters for dice-roll entries and outcomes.

  Shared by the chat timeline (`format_line/1`) and the dice modal
  (`format_dice/1`, `format_against_spaced/1`). Extracted from
  `DragonexWeb.GameLive.Show` so the formatting rules live in one place — the
  inline chat line and the modal card each carried their own near-identical copy
  of the dice/mod/total assembly, and the outcome lookup was duplicated across
  three 16-case tables (atom + string arms).
  """

  alias Dragonex.RollTotals

  use Gettext, backend: Dragonex.Gettext

  # Valid outcome keys; their labels resolve at render time (`outcome_tuple/1`)
  # so they follow the viewer's locale.
  @outcome_keys [:hit, :crit, :miss, :success, :failure, :revive, :crit_fail]

  @doc "Normalize an outcome value (atom or string) to its atom key, or nil."
  @spec normalize_outcome(term()) :: atom() | nil
  def normalize_outcome(o) when is_atom(o), do: o

  def normalize_outcome(o) when is_binary(o) do
    # Outcomes come from jsonb payload; the only valid keys are the @outcome_keys
    # atoms, which are already loaded. Use to_existing_atom (D8) so a stray
    # string can't grow the atom table.
    String.to_existing_atom(o)
  rescue
    ArgumentError -> nil
  end

  def normalize_outcome(_), do: nil

  # outcome -> {inline_chat_marker, modal_label, css_class}
  defp outcome_tuple(o) do
    case normalize_outcome(o) do
      key when key in @outcome_keys -> outcome_labels(key)
      _ -> {"", "", "dg-neutral"}
    end
  end

  defp outcome_labels(:hit),
    do: {dgettext("ui", "→ ¡ACIERTO!"), dgettext("ui", "¡Acierto!"), "dg-win"}

  defp outcome_labels(:crit),
    do: {dgettext("ui", "→ ¡CRÍTICO!"), dgettext("ui", "¡Crítico!"), "dg-win"}

  defp outcome_labels(:miss), do: {dgettext("ui", "→ fallo"), dgettext("ui", "Fallo"), "dg-lose"}

  defp outcome_labels(:success),
    do: {dgettext("ui", "→ éxito"), dgettext("ui", "Éxito"), "dg-win"}

  defp outcome_labels(:failure),
    do: {dgettext("ui", "→ fallo"), dgettext("ui", "Fallo"), "dg-lose"}

  defp outcome_labels(:revive),
    do: {dgettext("ui", "→ ¡revive!"), dgettext("ui", "¡Revive!"), "dg-win"}

  defp outcome_labels(:crit_fail),
    do: {dgettext("ui", "→ ¡PIFIA!"), dgettext("ui", "¡Pifia! (2 fallos)"), "dg-lose"}

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
      ["ac", n] -> {n, dgettext("ui", "CA")}
      ["dc", n] -> {n, dgettext("ui", "DC")}
      {:ac, n} -> {n, dgettext("ui", "CA")}
      {:dc, n} -> {n, dgettext("ui", "DC")}
      _ -> nil
    end
  end

  @doc "Compact \"vs CA n\" for the chat line (no leading space)."
  @spec format_against(term()) :: String.t()
  def format_against(v) do
    case against_kind_n(v) do
      {n, kind} -> dgettext("ui", "vs %{kind} %{value}", kind: kind, value: n)
      nil -> ""
    end
  end

  @doc "\" vs CA n\" for the dice modal (leading space)."
  @spec format_against_spaced(term()) :: String.t()
  def format_against_spaced(v) do
    case against_kind_n(v) do
      {n, kind} -> " " <> dgettext("ui", "vs %{kind} %{value}", kind: kind, value: n)
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
    reason = p["reason"] || p[:reason] || dgettext("ui", "tirada")
    total = p["total"] || p[:total]

    {dice_str, dice_sum} = dice_parts(dice)
    mod = RollTotals.modifier(p, dice_sum)

    parts = [reason, dice_str]

    parts =
      case mod do
        n when is_number(n) and n > 0 -> parts ++ ["+#{n}"]
        n when is_number(n) and n < 0 -> parts ++ ["#{n}"]
        _ -> parts
      end

    parts = if is_number(total), do: parts ++ ["= #{total}"], else: parts
    parts = append_if(parts, RollTotals.minimum_note(p))
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
    mod = RollTotals.modifier(g, dice_sum)

    mod_str =
      cond do
        mod == nil -> ""
        mod > 0 -> " +#{mod}"
        mod < 0 -> " #{mod}"
        true -> ""
      end

    total_str = if is_number(total), do: " = #{total}", else: ""

    note = RollTotals.minimum_note(g)
    minimum_str = if note == "", do: "", else: " #{note}"

    "#{dice_str}#{mod_str}#{total_str}#{minimum_str}"
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
