defmodule Dragonex.Text.Lexicon do
  @moduledoc """
  Language-specific vocabulary of `Dragonex.Text`.

  `Dragonex.Text` keeps the language-neutral algorithm (actor tags, leaked
  tool tokens, markdown tables, battlemaps, UTF-8, clause splitting, name
  ownership). Every word list or pattern that only makes sense for one
  language lives in a lexicon module:

    * `Dragonex.Text.Lexicon.Es` — the original Castilian heuristics, moved
      verbatim (Spanish output must stay byte-identical).
    * `Dragonex.Text.Lexicon.En` — English equivalents with the same intent.

  The lexicon is chosen at call time from the per-process locale
  (`Dragonex.I18n.locale/0`). Patterns are compiled as module attributes, so
  selecting one costs a process-dictionary lookup, not a regex compilation.

  History labels are not tied to a locale: a stray Spanish or English label
  (`Turno de X` / `Turn of X`, `[X declara]` / `[X declares]`) must never leak,
  whichever language the table plays in. Those shared patterns live here.
  """

  alias Dragonex.Text.Lexicon.{En, Es}

  @doc "Lexicon module of the active locale."
  @spec current() :: module()
  def current, do: for_locale(Dragonex.I18n.locale())

  @doc "Lexicon module for a locale (`:en` → English, anything else → Spanish)."
  @spec for_locale(atom()) :: module()
  def for_locale(:en), do: En
  def for_locale(_), do: Es

  # Bilingual history scaffolding pasted mid-prose without a colon:
  # `[Turno de Thane]`, `[Turn of Thane]`, `[Vex declara]`, `[Vex declares]`.
  @stray_history_labels [
    ~r/\[(?:Turno de|Turn of)\s+[^\]\n]{1,40}\]\s*:?\s*/u,
    ~r/\[[^\]\n]{1,40}\s+(?:declara|declares)\]\s*:?\s*/u
  ]

  @doc "Patterns of bracketed history labels (both languages) that must never leak."
  def stray_history_labels, do: @stray_history_labels

  # `[→ Thane decide]` (Spanish history) and `[→ Thane decides]` (English).
  @decision_marker ~r/\[→\s*[^\]\n]{1,40}\s+decides?\]\s*:?\s*/u

  @doc "Bracketed decision marker in either language."
  def decision_marker, do: @decision_marker
end
