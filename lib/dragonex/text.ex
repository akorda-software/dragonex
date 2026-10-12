defmodule Dragonex.Text do
  @moduledoc """
  Sanitizes model output so the chat timeline shows clean prose, not the
  scaffolding the agents leak from their shared history.

  ## Why this exists

  `Dragonex.History.from_events/1` attributes each past line to its actor with
  tags like `[Vex]: ...` and `[R2 · combate · Turno de Vex] [Vex]: ...` so the
  model knows who said what across agents. The model then tends to **imitate**
  those tags in its own output — narrating as `[DM]: ...` or stamping turn
  headers on its prose. DeepSeek also leaks raw tool-call tokens
  (`<｜DSML｜...>`) and models occasionally produce markdown tables or ASCII
  battlemaps. None of that should reach the player.

  `scrub/1` is applied in `Dragonex.Events` before persisting a model
  narration (so the stored event is always clean). `History.from_events/1`
  then sanitizes UTF-8 and adds attribution tags — it does not re-scrub.

  Idempotent: scrubbing already-clean text is a no-op.

  ## Language

  Every heuristic that depends on the language of the prose (turn labels,
  stat words, meta phrases, puppeting verbs, speech and question detection)
  reads its vocabulary from `Dragonex.Text.Lexicon`, selected by the
  per-process locale (`Dragonex.I18n.locale/0`): Castilian with `:es`
  (the original behaviour), English with `:en`. Structural steps (actor
  tags, leaked tool tokens, tables, battlemaps, UTF-8) are shared.
  """

  alias Dragonex.Text.Lexicon

  defp lx, do: Lexicon.current()

  @doc """
  Strip model-output noise and return clean prose. Order matters: the turn
  header is often prefixed by an actor tag, so we strip the leading tag(s)
  first, then the turn header, then deal with line-level noise (tables,
  battlemaps, leaked tokens), and finally collapse whitespace.

  The `actor/1` arity additionally strips a leading self-reference: when a PC
  bot narrates in third person starting with its own name ("Lyra levanta..."),
  the leading name is dropped — the chat card / streaming bubble already labels
  the actor, so keeping it would render "LyraLyra levanta...". Passing the actor
  only ever strips THAT actor's name at the very start, so DM narration like
  "Lyra cae herida" (actor "dm") is untouched.
  """
  @spec scrub(binary()) :: binary()
  def scrub(text) when is_binary(text), do: scrub(text, nil, [])

  @spec scrub(binary(), binary() | nil) :: binary()
  def scrub(text, actor) when is_binary(text), do: scrub(text, actor, [])
  def scrub(other, _actor), do: other

  @spec scrub(binary(), binary() | nil, keyword()) :: binary()
  def scrub(text, actor, opts) when is_binary(text) and is_list(opts) do
    names = narration_names(actor, opts)

    text
    |> strip_leading_actor_tags()
    |> strip_inline_actor_tags()
    |> strip_leading_turn_header()
    |> strip_inline_history_headers()
    |> unwrap_markdown_emphasis()
    |> strip_orphan_emphasis()
    |> maybe_strip_leading_self_name(actor, names)
    |> strip_fused_roll_label(actor)
    |> strip_leaked_tool_tokens()
    |> drop_combat_recap_blocks()
    |> drop_inline_stats()
    |> cleanup_after_stat_strip()
    |> drop_narrated_dice_syntax()
    |> drop_narrated_tool_invocations()
    |> drop_engine_meta_phrases()
    |> maybe_strip_puppet_clauses(actor, names)
    |> maybe_strip_pc_world_leaks(actor, names)
    |> maybe_strip_solo_exec(actor, opts)
    |> drop_markdown_tables()
    |> drop_ascii_battlemaps()
    |> collapse_blank_lines()
    |> sanitize_utf8()
    |> String.trim()
  end

  def scrub(other, _actor, _opts), do: other

  @doc """
  Strip invalid UTF-8 bytes so the result is always JSON-serializable.

  Why this exists: the model occasionally emits a stray lead byte (e.g. `0xC2`)
  without its continuation — a truncated multibyte char. Jason then raises
  `EncodeError` when serializing the request, which surfaces as
  `{:model_request_failed, %Jason.EncodeError{...}}`. Once such a byte lands in
  a persisted narration, EVERY subsequent beat fails (the history carries it
  forever) and the partida wedges: every beat → "titubea" → circuit-breaker
  pause, and resuming just fails again because the bad byte is still there.

  We strip byte-by-byte: `:unicode.characters_to_binary/2` returns the valid
  prefix and the offending tail; we drop one byte and recurse. The result is
  guaranteed clean UTF-8.
  """
  @spec sanitize_utf8(binary()) :: binary()
  def sanitize_utf8(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8) do
      {:error, valid, rest} -> valid <> sanitize_utf8(drop_leading_byte(rest))
      {:incomplete, valid, _rest} -> valid
      result when is_binary(result) -> result
    end
  end

  defp drop_leading_byte(<<_::8, rest::binary>>), do: rest
  defp drop_leading_byte(<<>>), do: <<>>

  # Leading `[Actor]:` / `[Actor declara]:` tags. The history uses these to
  # attribute voice; the model imitates them. Strip every leading one (some
  # responses pile two: `[R2 · Turno de DM] [DM]: ...`).
  defp strip_leading_actor_tags(text), do: strip_actor_loop(text, 4)

  defp strip_actor_loop(text, 0), do: text

  defp strip_actor_loop(text, n) do
    leading_actor_tag = ~r/^(?:\[[^\]\n]{1,60}\][:\s]*)+/

    case Regex.run(leading_actor_tag, text, return: :index) do
      [{0, len} | _] when len > 0 ->
        text
        |> binary_part(len, byte_size(text) - len)
        |> strip_actor_loop(n - 1)

      _ ->
        text
    end
  end

  # Mid-prose leaks: "... rezad. [DM]: El pastor se levanta...". Only match
  # `]:` (colon), never markdown links `](url)`.
  defp strip_inline_actor_tags(text) do
    String.replace(text, ~r/\[[^\]\n]{1,60}\]\s*:\s*/u, "")
  end

  # Leading turn header in two shapes the history emits:
  #   "R2 · combate · Turno de Vex"
  #   "R2 · Turno de DM"
  # The model sometimes absorbs these from the history prefix and starts its
  # narration with the same line. Strip if it's literally the first thing.
  defp strip_leading_turn_header(text) do
    turn_header = ~r/^R\d+(?:\s*·\s*[^\n]{1,40}){0,3}\s*[:.\-]?\s*/m

    case Regex.run(turn_header, text, return: :index) do
      [{0, len} | _] when len > 0 ->
        binary_part(text, len, byte_size(text) - len)

      _ ->
        text
    end
  end

  # Mid-prose history scaffolding. `strip_inline_actor_tags` only matches
  # `[…]:` (colon). The model also pastes `[R2 · Turno de Thane]` and
  # `[→ Thane decide]` without a colon, anywhere in the paragraph.
  defp strip_inline_history_headers(text) do
    text
    |> String.replace(~r/\[R\d+(?:\s*·\s*[^\]]{1,60}){0,4}\]\s*:?\s*/u, "")
    |> String.replace(Lexicon.decision_marker(), "")
    |> then(
      &Enum.reduce(Lexicon.stray_history_labels(), &1, fn re, acc ->
        String.replace(acc, re, "")
      end)
    )
  end

  # Dice-card leak: the model (or a glued who-chip) writes "Lyrachequeo de
  # Inteligencia". Leading self-name already covers the start of a beat;
  # this catches the same fuse mid-prose. ThaneSe/LyraSe stays in
  # strip_leading_self_name.
  defp strip_fused_roll_label(text, actor) when is_binary(actor) and actor != "" do
    escaped = Regex.escape(actor)

    case Regex.compile("#{escaped}(?=#{lx().fused_roll_words()})", "iu") do
      {:ok, re} -> String.replace(text, re, "")
      {:error, _} -> text
    end
  end

  defp strip_fused_roll_label(text, _), do: text

  # A PC bot narrating in third person often opens with its own name
  # ("Lyra levanta...", "—Lyra:", "*Lyra desenfunda..."). The card/bubble
  # already labels the actor, so the leading self-name would render doubled
  # ("LyraLyra levanta..."). Drop a leading "<name>" (optionally preceded by an
  # em-dash or markdown asterisks) followed by a separator. Only the ACTOR's own
  # name at the very start is touched — a DM's "Lyra cae herida" (actor "dm") is
  # safe because the passed actor isn't "Lyra". The trailing `\s` requirement
  # keeps "Lyranthropo" and bare "Lyra." (end of a full sentence) intact.
  defp strip_leading_self_name(text, nil), do: text
  defp strip_leading_self_name(text, ""), do: text

  defp strip_leading_self_name(text, actor) when is_binary(actor) do
    escaped = Regex.escape(actor)
    text = strip_english_possessive(text, escaped)

    # Match the actor name at the very start, optionally wrapped in markdown
    # bold/italic (`**Thane**`, `*Lyra*`) and/or preceded by an em-dash. After
    # the name we allow an optional closing run of `*` (the bold close), then
    # require ONE of:
    #   * a separator punctuation + space   ("Thane: ...", "Thane, ...")
    #   * whitespace                        ("Thane deja ...")
    #   * a lowercase letter (lookahead)    ("Thanedeja ..." — DeepSeek glues
    #                                        the name to the next word). Safe
    #                                        because PC names aren't prefixes
    #                                        of real Spanish words.
    # The closing `*` group is what lets us strip the common "**Thane**deja"
    # form; without it the model's markdown bold defeated the strip.
    case Regex.compile(
           "^(?:—\\s*)?(?:\\*+\\s*)?#{escaped}(?:\\*+\\s*)?(?:[:：,.]\\s*|\\s+|(?=[a-zá-úñ])|(?=Se\\s)|(?=Me\\s))",
           ""
         ) do
      {:ok, re} ->
        case String.replace(text, re, "", global: false) do
          ^text -> text
          stripped -> capitalize_sentence(stripped)
        end

      {:error, _} ->
        text
    end
  end

  defp maybe_strip_leading_self_name(text, actor, names) do
    speaker = text |> String.trim_leading() |> String.replace(~r/^—\s*/u, "")

    case matching_name(speaker, names.all) do
      nil -> strip_leading_self_name(text, actor)
      name -> if same_name?(name, names.own), do: strip_leading_self_name(text, actor), else: text
    end
  end

  defp strip_english_possessive(text, escaped) do
    case Regex.compile("^(?:—\\s*)?#{escaped}'s(?:\\s+\\w+)?\\s+", "u") do
      {:ok, re} ->
        case String.replace(text, re, "", global: false) do
          ^text -> text
          stripped -> capitalize_sentence(stripped)
        end

      {:error, _} ->
        text
    end
  end

  defp unwrap_markdown_emphasis(text) do
    text
    |> String.replace(~r/\*\*([^*]+)\*\*/u, "\\1")
    |> String.replace(~r/\*([^*]+)\*/u, "\\1")
  end

  defp strip_orphan_emphasis(text), do: String.replace(text, ~r/\*+/u, "")

  defp capitalize_sentence(text) do
    case String.next_grapheme(String.trim_leading(text)) do
      {g, rest} ->
        if Regex.match?(~r/^[a-záéíóúüñ]$/u, g), do: String.upcase(g) <> rest, else: text

      _ ->
        text
    end
  end

  # DeepSeek-V4 leaks its internal tool-call tokens into the text stream:
  #   <｜DSML｜function_calls> ... <｜DSML｜/function_calls>
  # These are NOT real OpenAI tool_calls (the provider would have parsed them),
  # they're plain text the model is dumping as if it were a reasoning trace.
  # Strip every `<｜...｜>...</...｜>` span, and any orphan `<｜...｜>` tag.
  defp strip_leaked_tool_tokens(text) do
    leaked_token_pair = ~r/<｜[^>]*｜[^>]*>.*?<\/[^>]*｜>/Us
    leaked_token_solo = ~r/<｜[^>]*｜[^>]*>/

    text
    |> String.replace(leaked_token_pair, "")
    |> String.replace(leaked_token_solo, "")
  end

  # Inline HP/CA leaks. The rule says don't reveal stats; when the model
  # disobeys, strip the numbers so the player never sees them. We keep the
  # surrounding sentence and just drop the offending pattern. Covered forms
  # (see the lexicons for each language's words):
  #   * "6/13 pg", "10/10 hp"            — current/max (the X/Y form)
  #   * "(13 → 6/13 pg)" envelopes
  #   * "le quedan 7 pg", "le quedan X"
  #   * "CA 15", "Clase de Armadura 13"   — armor class
  #   * "7 pg", "10 hp", "p.g."           — bare current HP
  #   * "7 puntos de golpe/vida"
  #   * "1 de los 7 puntos de vida originales"
  # Conservative on bare numbers: a digit only counts as HP when followed
  # explicitly by an HP unit, so "15 de oro" or "3 puertas" are left alone.
  defp drop_inline_stats(text) do
    text
    |> String.replace(lx().stats_parens(), "")
    |> String.replace(lx().inline_of_total(), "")
    |> String.replace(lx().inline_hp_xy(), "")
    |> String.replace(lx().inline_points(), "")
    |> String.replace(lx().inline_bare_hp(), "")
    |> String.replace(lx().inline_ac_long(), "")
    |> String.replace(lx().inline_ac(), "")
    |> String.replace(~r/\(\s*\d{1,4}\s*→\s*\)/, "")
    |> String.replace(lx().hp_left(), "")
    |> drop_dice_notation()
  end

  # After stripping HP/CA numbers, the model often leaves broken bold shells
  # from the playtest: `**Sabueso: **`, `**Rhogar **`, `queda con **1 de **`.
  # Cosmetic cleanup only — never invents content.
  defp cleanup_after_stat_strip(text) do
    text
    # `**Name: **` / `**Name:**` empty status after the colon
    |> String.replace(~r/\*\*[^*]{0,80}:\s*\*\*/u, "")
    # Empty bold `****` or `** **`
    |> String.replace(~r/\*\*\s*\*\*/, "")
    # Bold that only wraps a bare name leftover (`**Rhogar **` → Rhogar)
    |> String.replace(
      ~r/\*\*\s*([A-Za-zÁÉÍÓÚÜÑáéíóúüñ][A-Za-zÁÉÍÓÚÜÑáéíóúüñ\s'-]{0,40}?)\s*\*\*/u,
      "\\1"
    )
    # Orphan "N de" / "N de **" when the unit (HP/pg) was stripped
    |> String.replace(lx().orphan_of(), "")
    # Dangling "queda con ." / "cae a ," / "recuperado por completo ."
    |> String.replace(lx().dangling_stat(), "")
    # Double spaces / space before punctuation left by removals
    |> String.replace(~r/[^\S\n]{2,}/u, " ")
    |> String.replace(~r/\s+([.,;:!?…])/u, "\\1")
  end

  # NdM[+mod] dice notation that leaks into prose ("daño 1d4+2", "golpea por
  # 2d6"). The dice modal shows rolls separately, so this is always a leak. We
  # only match a count prefix (1d6, 2d8) to avoid clobbering standalone "d20"
  # that might appear in legitimate prose; "d20" alone is handled by the
  # engine-signature pattern in drop_narrated_dice_syntax.
  @dice_notation ~r/\b\d{1,2}d\d{1,3}(?:\s*[+-]\s*\d{1,3})?\b/

  defp drop_dice_notation(text) do
    String.replace(text, @dice_notation, "")
  end

  # Lines that echo the engine's dice syntax into prose. The shared history the
  # model reads carries roll lines like "[🎲 Vex] ataque ... d20:14 = 14 vs CA
  # 10", and sometimes the model IMITATES that format instead of emitting a real
  # tool_call — leaking a half-formed line such as
  #   "Vexataque a Golem de entrenamiento con shortbow d20: +5 vs"
  # into the narration. Real prose never writes "d20: <number>" (the dice modal
  # shows rolls separately), so any line matching that engine signature is a
  # leak and is dropped wholesale.
  @narrated_dice_syntax ~r/\bd\d{1,3}\s*[:=]\s*[+-]?\d/

  defp drop_narrated_dice_syntax(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(Regex.match?(@narrated_dice_syntax, &1) and line_looks_like_tool_leak?(&1)))
    |> Enum.join("\n")
  end

  # Guard so we only drop lines that ALSO look like a narrated tool invocation
  # (a verb of the engine's tool surface + a target/weapon). This protects real
  # prose that happens to mention a die, like "tiré un d20: salió un 15" — rare,
  # but we'd rather under-clean than mangle legitimate narration.
  defp line_looks_like_tool_leak?(line) do
    Regex.match?(lx().tool_leak_words(), line)
  end

  # These appear when the model recaps HP per combatant. Drop the whole block:
  # the header line + any following list of "<name>: ... pg" / "<name> (X/Y)".
  # Accept markdown bold on either side of the colon: `**Estado del Combate:**`,
  # `**Estado del Combate**:`, `Estado del Combate:`.
  defp drop_combat_recap_blocks(text) do
    lines = String.split(text, "\n")
    recap_headers = lx().recap_headers()

    {dropped, kept} =
      Enum.reduce(lines, {false, []}, fn line, {in_block, acc} ->
        cond do
          # Header opens a recap block — start dropping.
          Regex.match?(recap_headers, line) ->
            {true, acc}

          # Inside a recap block: list rows (- name: X/Y pg, - name (X/Y)) stay dropped.
          in_block and recap_row?(line) ->
            {true, acc}

          # Inside a recap block but the line doesn't look like a list row —
          # the block has ended; keep this line.
          in_block ->
            {false, [line | acc]}

          true ->
            {false, [line | acc]}
        end
      end)

    _ = dropped
    kept |> Enum.reverse() |> Enum.join("\n")
  end

  # Lines that look like recap rows: bullet lists with pg/hp numbers, or
  # standalone "Name: X/Y" status lines.
  defp recap_row?(line) do
    trimmed = String.trim(line)
    starts_with_bullet? = String.starts_with?(trimmed, ["-", "*", "+"])

    has_stats? =
      Regex.match?(lx().recap_row_hp(), trimmed) or
        Regex.match?(lx().recap_row_ac(), trimmed)

    starts_with_bullet? and has_stats?
  end

  # Engine meta phrases that leak internal vocabulary into the prose:
  # "el sistema resuelve...", "el motor decide...", "la herramienta devuelve..."
  # Plus DM fourth-wall breaks: "la escena se resetea", "lo materializo en el
  # mundo para que sea oficial", "como DM yo...", "para que conste/sea oficial".
  # These break immersion — the model is describing its own mechanics or
  # narrating the engine instead of the fiction.
  defp drop_engine_meta_phrases(text) do
    Enum.reduce(lx().engine_meta(), text, &String.replace(&2, &1, ""))
  end

  # Tool calls the model WRITES into the prose instead of emitting as real
  # tool_calls. Two shapes appear in the wild:
  #   * function-like:  "establish_fact("...")", "spawn_monster("goblin","g1")"
  #   * bracketed tags: "[Establecer hecho: ...]", "[Hecho: ...]", "[Spawn: ...]"
  # Both are noise the player should never see. The real tool call (if any) was
  # emitted separately and resolved by the engine; this is the model narrating
  # the invocation as text.
  @narrated_tool_calls ~r/\b(?:record_npc_statement|establish_fact|spawn_monster|set_scene|make_attack|cast_spell|roll_initiative|ability_check|end_combat|level_up|apply_condition|remove_condition|heal|grant_temp_hp|grant_xp|drop_concentration|start_rage|end_rage|start_reckless|end_reckless|second_wind|action_surge|flurry_of_blows|hunters_mark|cunning_action_hide|start_uncanny_dodge|create_spell_slot|convert_to_sorcery_points|arm_metamagic|divine_smite|end_smite|lay_on_hands|divine_sense|turn_undead|bardic_inspiration|arcane_recovery|wild_shape|end_wild_shape|make_death_save|short_rest|long_rest)\s*\([^)]*\)/i

  defp drop_narrated_tool_invocations(text) do
    text
    |> String.replace(@narrated_tool_calls, "")
    |> String.replace(lx().narrated_tool_brackets(), "")
  end

  # Markdown tables: a header row of |...|...| followed by a separator row of
  # |---|---| (or :|:-:|:--). They're noise to the player; drop the header +
  # separator + body rows. We only pop the previous line when it itself looked
  # like a table row (starts and ends with `|`) — so a regular prose lead-in
  # like "Tabla:" just before the separator is preserved.
  defp drop_markdown_tables(text) do
    md_table_separator = ~r/^\|[ :\-\s|]+\|\s*$/

    text
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {_dropped_prev, acc} ->
      cond do
        Regex.match?(md_table_separator, line) ->
          # The header row sits on top of acc. Only pop it if it really looks
          # like a table row — otherwise it's prose that just preceded the
          # table (e.g. "Esto es una tabla:") and must be kept.
          new_acc =
            case acc do
              [prev | rest] when is_binary(prev) ->
                trimmed = String.trim(prev)

                if String.starts_with?(trimmed, "|") and String.ends_with?(trimmed, "|"),
                  do: rest,
                  else: acc

              _ ->
                acc
            end

          {true, new_acc}

        String.starts_with?(String.trim(line), "|") and String.ends_with?(String.trim(line), "|") ->
          {true, acc}

        true ->
          {false, [line | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # ASCII battlemaps: lines with 2+ box-drawing chars (║ ╔ ╗ ╚ ╝ ═ and friends)
  # anywhere on the line. A real prose paragraph essentially never has even one,
  # so 2+ is a safe noise threshold. PCRE's \x{} rejects codepoints this high
  # on Erlang's regex engine, so we test by codepoint directly.
  defp drop_ascii_battlemaps(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&box_drawing_line?/1)
    |> Enum.join("\n")
  end

  # True if a line carries 2+ box-drawing codepoints (Unicode 0x2500–0x257F).
  defp box_drawing_line?(line) do
    line
    |> String.to_charlist()
    |> Enum.count(&box_drawing?/1) >= 2
  end

  defp box_drawing?(cp) when cp >= 0x2500 and cp <= 0x257F, do: true
  defp box_drawing?(_), do: false

  # Collapse 3+ consecutive newlines to 2 (paragraph break), and trim trailing
  # spaces per line. Leaves intentional paragraph breaks intact.
  defp collapse_blank_lines(text) do
    text
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/[^\S\n]{2,}/u, " ")
  end

  # ---------------------------------------------------------------------------
  # Structural table-feel cuts (D7 / D29). Prompt nudges leak; we drop the
  # clause instead of trusting the next beat.
  # ---------------------------------------------------------------------------

  # The vocabulary of these cuts (proactive verbs, clitics/adverbs, party
  # subjects, implicit plural movement, environment nouns) lives in the
  # locale lexicon; see `Dragonex.Text.Lexicon.Es` / `.En`.
  @quoted_span ~r/((?:«[^»]*(?:»|$)|“[^”]*(?:”|$)|"[^"]*(?:"|$)))/u

  @doc """
  True when `text` describes a PC performing a proactive action (rule 14 leak).
  """
  @spec dm_puppets_pc?(String.t(), [String.t()]) :: boolean()
  @spec dm_puppets_pc?(String.t(), [String.t()], [String.t()]) :: boolean()
  def dm_puppets_pc?(text, pc_names, character_names \\ [])

  def dm_puppets_pc?(text, pc_names, character_names)
      when is_binary(text) and is_list(pc_names) and is_list(character_names) do
    %{targets: targets} =
      narration_names("dm", pc_names: pc_names, character_names: character_names)

    text = unwrap_markdown_emphasis(text)

    targets != [] and
      (Regex.match?(puppet_anywhere_pattern(targets), text) or
         Regex.match?(puppet_relative_pattern(targets), text) or
         Enum.any?(split_puppet_clauses(text, lx().collective_heads()), fn clause ->
           collective_action_clause?(clause) or strip_implicit_party_action(clause) != clause
         end))
  end

  def dm_puppets_pc?(_, _, _), do: false

  @doc "Detect a proactive clause removed by roster-aware sanitization, preserving NPC invitations."
  @spec puppets_pc?(String.t(), String.t() | nil, [String.t()], [String.t()]) :: boolean()
  def puppets_pc?(text, actor, pc_names, character_names \\ [])

  def puppets_pc?(text, actor, pc_names, character_names)
      when is_binary(text) and is_list(pc_names) and is_list(character_names) do
    names = narration_names(actor, pc_names: pc_names, character_names: character_names)
    targets = names.targets

    text = unwrap_markdown_emphasis(text)

    if targets == [] do
      false
    else
      # Compare against the same clause normalization so newlines or spaces
      # cannot turn a legitimate scene into a false rejection.
      original =
        text |> split_puppet_clauses(targets ++ lx().collective_heads()) |> join_clauses()

      do_strip_puppet_clauses(text, names) != original
    end
  end

  def puppets_pc?(_, _, _, _), do: false

  @doc """
  Drop clauses that start with `<PC> <action-verb>` and bounded proactive
  relatives (`"Miro a Lyra, que sigue hojeando..."`) and `cuando`/`mientras`
  subordinates. Unambiguous short names share the canonical PC's ownership;
  `scrub/3` also accepts `:character_names` to disambiguate registered NPCs.
  Explicit party subjects and committed plural movement are also cut when
  they act for another PC; qualified NPC groups and invitations are preserved.
  Passive state
  (`Lyra está herida`, `Lyra cae herida`) is kept — those verbs are not
  in the action list. A mention mid-clause (`junto a Lyra, el tabernero
  abre`) is also kept. A PC narrator passes only the names of OTHER PCs,
  retaining its own actions and speech.
  """
  @spec strip_puppet_clauses(String.t(), [String.t()]) :: String.t()
  def strip_puppet_clauses(text, pc_names)
      when is_binary(text) and is_list(pc_names) do
    do_strip_puppet_clauses(text, narration_names("dm", pc_names: pc_names))
  end

  def strip_puppet_clauses(text, _), do: text

  defp do_strip_puppet_clauses(text, %{targets: targets, all: all}) do
    if targets == [] do
      text
    else
      re = puppet_subject_pattern(targets)

      {kept, _} =
        text
        |> strip_relative_pc_actions(targets)
        |> strip_subordinate_pc_actions(targets)
        |> split_puppet_clauses(targets ++ lx().collective_heads())
        |> Enum.flat_map(&split_pc_environment_tail(&1, re))
        |> Enum.map(&strip_implicit_party_action/1)
        |> Enum.reduce({[], false}, fn clause, {kept, previous_pc?} ->
          cond do
            clause == "" ->
              {kept, true}

            Regex.match?(re, clause) ->
              {kept, true}

            collective_action_clause?(clause) ->
              {kept, true}

            quoted_pc_speech?(clause, targets, all, previous_pc?) ->
              {kept, true}

            true ->
              {[clause | kept], false}
          end
        end)

      kept
      |> Enum.reverse()
      |> join_clauses()
    end
  end

  defp collective_action_clause?(clause) do
    not String.contains?(clause, "?") and
      Enum.any?(lx().collective_patterns(), &Regex.match?(&1, clause))
  end

  defp split_pc_environment_tail(clause, subject_re) do
    if Regex.match?(subject_re, clause) do
      # Search only outside quotations, including partial streamed quotes.
      {index, _offset} =
        Regex.split(@quoted_span, clause, include_captures: true)
        |> Enum.reduce({nil, 0}, fn segment, {found, offset} ->
          match =
            if is_nil(found) and not String.starts_with?(segment, ["«", "“", "\""]) do
              case Regex.run(lx().pc_environment_tail(), segment, return: :index) do
                [{start, length}] -> {offset + start, length}
                _ -> nil
              end
            end

          {found || match, offset + byte_size(segment)}
        end)

      case index do
        {start, length} ->
          tail_start = start + length
          tail = binary_part(clause, tail_start, byte_size(clause) - tail_start)

          [
            binary_part(clause, 0, start),
            Regex.replace(~r/^\p{Ll}/u, tail, &String.upcase/1)
          ]

        nil ->
          [clause]
      end
    else
      [clause]
    end
  end

  defp strip_implicit_party_action(clause) do
    segments = Regex.split(@quoted_span, clause, include_captures: true)
    unquoted = Enum.reject(segments, &String.starts_with?(&1, ["«", "“", "\""])) |> Enum.join()

    if String.contains?(unquoted, ["¿", "?"]) or
         Regex.match?(lx().implicit_party_plan(), unquoted) do
      clause
    else
      clean =
        segments
        |> Enum.map_join(fn segment ->
          if String.starts_with?(segment, ["«", "“", "\""]) do
            segment
          else
            stripped =
              segment
              |> String.replace(lx().implicit_party_movement(), "")
              |> String.replace(lx().implicit_party_gesture(), "")

            if stripped == segment,
              do: segment,
              else: String.replace(stripped, ~r/\s+([,.!?…;:])/u, "\\1")
          end
        end)

      if clean == clause do
        clause
      else
        clean =
          clean
          |> String.replace(lx().trailing_conj(), "")
          |> String.trim()
          |> String.trim_trailing(",")

        cond do
          Regex.match?(~r/^[,;.!?…:]*$/u, clean) ->
            ""

          Regex.match?(lx().implicit_lead(), clause) ->
            Regex.replace(~r/^\p{Ll}/u, clean, &String.upcase/1)

          true ->
            clean
        end
      end
    end
  end

  defp maybe_strip_puppet_clauses(text, "dm", names) do
    do_strip_puppet_clauses(text, names)
  end

  defp maybe_strip_puppet_clauses(text, actor, names)
       when is_binary(actor) and actor not in ["", "turnmaster", "system"] do
    do_strip_puppet_clauses(text, names)
  end

  defp maybe_strip_puppet_clauses(text, _actor, _names), do: text

  # A short form is inferred only when every registered character agrees on
  # its owner. Keep canonical names and match the longest form first, so
  # "Lyra del Mar" never becomes another participant's "Lyra" attribution.
  defp narration_names(actor, opts) do
    pcs = canonical_names(Keyword.get(opts, :pc_names, []))

    own =
      if is_binary(actor) and actor not in ["", "dm", "turnmaster", "system"],
        do: [actor],
        else: []

    registered =
      canonical_names(pcs ++ canonical_names(Keyword.get(opts, :character_names, [])) ++ own)

    actor_name = if is_binary(actor), do: String.downcase(actor), else: ""
    targets = Enum.reject(pcs, &(String.downcase(&1) == actor_name))

    ambiguous =
      registered
      |> Enum.group_by(&first_name/1)
      |> Enum.filter(fn {_first, owners} -> length(owners) > 1 end)
      |> Enum.map(&elem(&1, 0))

    %{
      targets: name_forms(targets, registered),
      all: name_forms(registered, registered),
      own: name_forms(own, registered),
      ambiguous: ambiguous
    }
  end

  defp canonical_names(names) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp canonical_names(_), do: []

  defp name_forms(names, registered) do
    owners = Enum.frequencies_by(registered, &first_name/1)

    names
    |> Enum.flat_map(fn name ->
      first = name |> String.split() |> hd()

      if first != name and owners[String.downcase(first)] == 1 and
           Regex.match?(~r/^\p{L}[\p{L}'’\-]{2,}$/u, first) do
        [name, first]
      else
        [name]
      end
    end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp first_name(name), do: name |> String.split() |> hd() |> String.downcase()

  defp matching_name(speaker, names) do
    Enum.find(names, fn name ->
      Regex.match?(Regex.compile!("^#{Regex.escape(name)}(?=$|\\s|[,.:：—])", "iu"), speaker)
    end)
  end

  defp same_name?(name, names),
    do: is_binary(name) and Enum.any?(names, &(String.downcase(&1) == String.downcase(name)))

  # The subject can be a reference within the current actor's own sentence:
  # "Miro a Lyra, que sigue hojeando sus pergaminos." Keep the reference and
  # the question, cutting only an immediate, bounded proactive relative.
  # Passive relatives and verbs belonging to a later NPC remain untouched.
  defp strip_relative_pc_actions(text, pc_names) do
    Regex.replace(puppet_relative_pattern(pc_names), text, fn _clause, name -> name end)
  end

  defp puppet_relative_pattern(pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    action = puppet_qualified_action()

    Regex.compile!(
      "(?<![\\p{L}\\p{N}_])(#{names_alt})(?=$|\\s|[,.:：—])\\s*,\\s*#{lx().relative_pronoun()}\\s+#{action}\\b" <>
        "[^,;.!?…:«»“”\"\\n]{0,180}(?:,|(?=[;.!?…:«»“”\"\\n]|$))",
      "iu"
    )
  end

  defp strip_subordinate_pc_actions(text, pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    re =
      Regex.compile!(
        "\\s+#{lx().subordinators()}\\s+(?:#{names_alt})(?=$|\\s|[,.:：—])" <>
          puppet_direct_predicate() <>
          "[^,;.!?…:«»“”\"\\n]{0,180}(?:,|(?=[;.!?…:«»“”\"\\n]|$))",
        "iu"
      )

    String.replace(text, re, "")
  end

  defp puppet_anywhere_pattern(pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    prefix = "(?:(?<![\\p{L}\\p{N}_])(?:#{names_alt})(?=$|\\s|[,.:：—]))"
    pattern = "#{prefix}#{puppet_direct_predicate()}"

    case Regex.compile(pattern, "iu") do
      {:ok, re} -> re
      {:error, _} -> ~r/^$/
    end
  end

  defp puppet_subject_pattern(pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    prefix = "^\\s*(?:—\\s*)?(?:\\*+\\s*)?(?:#{names_alt})(?:\\*+\\s*)?(?=$|\\s|[,.:：—])"
    pattern = "#{prefix}#{puppet_direct_predicate()}"

    case Regex.compile(pattern, "iu") do
      {:ok, re} -> re
      {:error, _} -> ~r/^$/
    end
  end

  defp puppet_direct_predicate do
    "(?:\\s*,[^.!?]{0,80},)?\\s+#{puppet_qualified_action()}\\b"
  end

  defp puppet_qualified_action, do: lx().puppet_qualified_action()

  # The general sentence splitter keeps quoted punctuation with its speaker.
  # A sentence that follows a closing quote can therefore share the NPC's
  # clause. Split only when a canonical PC starts there, preserving NPC voice
  # and attributions such as «¡Alto!» —grita el goblin.
  defp split_puppet_clauses(text, pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    boundary =
      Regex.compile!(
        "(?<=[.!?…][»”\"])[.!?…]?\\s+(?=(?:#{names_alt})(?=$|\\s|[,.:：—]))",
        "iu"
      )

    text |> split_clauses() |> Enum.flat_map(&Regex.split(boundary, &1, trim: true))
  end

  defp quoted_pc_speech?(clause, pc_names, all_names, previous_pc?) do
    case Regex.run(~r/^[«“"].*[»”"](?<suffix>.*)$/us, clause, capture: ["suffix"]) do
      [suffix] ->
        case attributed_speaker(suffix) do
          nil ->
            # Keep the removed PC's implicit speech out while its attribution
            # is incomplete or has no named speaker (e.g. "—comenta."). An
            # explicit NPC attribution below still preserves that NPC's voice.
            previous_pc?

          speaker ->
            same_name?(matching_name(speaker, all_names), pc_names)
        end

      _ ->
        previous_pc? and Regex.match?(~r/^[«“"]/u, String.trim_leading(clause))
    end
  end

  # Speaker named after a closing quote: verb-first in both languages
  # («…», dice Lyra / "…," says Lyra) and, in English, name-first
  # ("…," Lyra says).
  defp attributed_speaker(suffix) do
    attribution = lx().speech_attribution()

    cond do
      Regex.match?(attribution, suffix) ->
        Regex.replace(attribution, suffix, "")

      name_first = lx().speech_attribution_name_first() ->
        case Regex.run(name_first, suffix, capture: :all_but_first) do
          [speaker] -> speaker
          _ -> nil
        end

      true ->
        nil
    end
  end

  @doc """
  Who a DM beat is asking, if anyone.

  Returns `{:named, "Thane"}` when an eligible PC name sits in the question,
  `:question` when the prose is a question to "you" / "qué hace" / ends
  in `¿…?` (English: contains `?`, "what do you do") without a single
  recipient, or `nil` when it is not a prompt to an eligible PC. Short forms
  use the same registered identities as narration; longer names and
  ambiguous short forms cannot become another PC's name.
  """
  @spec addressed_pc(String.t(), [String.t()]) :: {:named, String.t()} | :question | nil
  @spec addressed_pc(String.t(), [String.t()], [String.t()]) ::
          {:named, String.t()} | :question | nil
  def addressed_pc(text, names, character_names \\ [])

  def addressed_pc(text, names, character_names) when is_binary(text) and is_list(names) do
    cleaned =
      text
      |> strip_inline_actor_tags()
      |> strip_inline_history_headers()
      |> String.trim()

    names = names |> canonical_names() |> Enum.reject(&(String.downcase(&1) == "dm"))
    registered = canonical_names(names ++ canonical_names(character_names))

    cond do
      cleaned == "" ->
        nil

      not question_to_pc?(cleaned) ->
        nil

      true ->
        case names_in_question(cleaned, registered) do
          [] ->
            :question

          [name] ->
            if same_name?(name, names), do: {:named, name}

          recipients ->
            if Enum.all?(recipients, &same_name?(&1, names)), do: :question
        end
    end
  end

  def addressed_pc(_, _, _), do: nil

  @doc """
  Canonical recipients of a literal leading vocative followed by a complete
  question (`Vex, ¿…?` / `Vex, can you…?`). This deliberately excludes
  mentions, quoted requests and indirect questions; semantic requests remain
  the model tool's responsibility.
  """
  @spec explicit_pc_recipients(String.t(), [String.t()]) :: [String.t()]
  @spec explicit_pc_recipients(String.t(), [String.t()], [String.t()]) :: [String.t()]
  def explicit_pc_recipients(text, names, character_names \\ [])

  def explicit_pc_recipients(text, names, character_names)
      when is_binary(text) and is_list(names) do
    case recipients_with_question(text, names, character_names) do
      {recipients, _start} -> recipients
      nil -> []
    end
  end

  def explicit_pc_recipients(_, _, _), do: []

  # Unique recipients of the leading vocative plus the byte offset where the
  # question starts (Spanish: the `¿`; English: right after the vocative).
  defp recipients_with_question(text, names, character_names) do
    names = names |> canonical_names() |> Enum.reject(&(String.downcase(&1) == "dm"))
    registered = canonical_names(names ++ canonical_names(character_names))
    text = String.trim(text)

    owners =
      Map.new(
        for name <- names,
            form <- name_forms([name], registered),
            do: {String.downcase(form), name}
      )

    with false <- owners == %{},
         {recipients, start} <- leading_vocative(text, owners) do
      if Enum.uniq(recipients) == recipients, do: {recipients, start}
    else
      _ -> nil
    end
  end

  defp leading_vocative(text, owners) do
    alternatives =
      owners
      |> Map.keys()
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map_join("|", &Regex.escape/1)

    pattern =
      Regex.compile!(
        "^(#{alternatives})(?=$|\\s*,|\\s+(?:#{lx().and_alt()})\\s+)(.*)$",
        "iu"
      )

    if lx().inverted_questions?() do
      with [_, vocative, question] <- Regex.run(lx().vocative_question(), text),
           false <- String.trim(question) == "" do
        start =
          case :binary.match(text, "¿") do
            {start, _} -> start
            :nomatch -> nil
          end

        {parse_vocative(String.trim(vocative), pattern, owners), start}
      else
        _ -> nil
      end
    else
      plain_leading_vocative(text, pattern, owners)
    end
  end

  # Without an opening `¿`, the vocative is the longest leading run of
  # comma-separated names that parses completely; the question is what
  # follows it up to the first `?`, within one sentence.
  defp plain_leading_vocative(text, pattern, owners) do
    offset =
      case Regex.run(~r/^[—–]\s*/u, text) do
        [lead] -> byte_size(lead)
        _ -> 0
      end

    body = binary_part(text, offset, byte_size(text) - offset)

    case :binary.match(body, "?") do
      {qpos, _} ->
        head = binary_part(body, 0, qpos)

        head
        |> :binary.matches(",")
        |> Enum.map(&elem(&1, 0))
        |> Enum.reverse()
        |> Enum.find_value(fn comma ->
          vocative = head |> binary_part(0, comma) |> String.trim()
          rest = binary_part(head, comma + 1, qpos - comma - 1)
          question = String.trim(rest)

          with false <- question == "" or String.contains?(question, [".", "!", "¿", "\n"]),
               [_ | _] = recipients <- parse_vocative(vocative, pattern, owners) do
            leading = byte_size(rest) - byte_size(String.trim_leading(rest))
            {recipients, offset + comma + 1 + leading}
          else
            _ -> nil
          end
        end)

      :nomatch ->
        nil
    end
  end

  @doc "Spoken leading PC vocative plus up to three informative/opinion questions and passive waiting, or nil."
  def literal_pc_speech(text, names, character_names \\ [])

  def literal_pc_speech(text, names, character_names) when is_binary(text) do
    with {spoken, questions} <- pc_question_parts(text, names, character_names),
         true <- Enum.all?(questions, &Regex.match?(lx().pc_question_information(), &1)) do
      scrub("—" <> spoken)
    else
      _ -> nil
    end
  end

  def literal_pc_speech(_, _, _), do: nil

  @doc "Up to three leading informative/opinion PC questions, passive waiting only, without an extra vocative clause."
  def pc_question_only?(text, names, character_names \\ []) do
    case pc_question_parts(text, names, character_names) do
      {_spoken, questions} ->
        Enum.all?(questions, fn question ->
          Regex.match?(lx().pc_question_information(), question) and
            not String.contains?(question, [",", ";", ":"])
        end)

      _ ->
        false
    end
  end

  defp pc_question_parts(text, names, character_names) when is_binary(text) do
    text = String.trim(text)

    with {[_ | _], start} when is_integer(start) <-
           recipients_with_question(text, names, character_names),
         body = binary_part(text, start, byte_size(text) - start),
         [_all, questions, tail] <- Regex.run(lx().question_run(), body),
         true <- Regex.match?(lx().pc_speech_wait(), String.trim(tail)) do
      # Preserve the complete speech and spaces between questions. Nothing
      # between them or after the passive wait can become a skipped action.
      speech = binary_part(text, 0, start) <> String.trim_trailing(questions)
      spoken = String.replace(speech, ~r/^[—–]\s*/u, "")
      {spoken, Regex.scan(lx().question_item(), questions) |> List.flatten()}
    else
      _ -> nil
    end
  end

  defp pc_question_parts(_, _, _), do: nil

  # Literal human declarations only: a question addressed to a qualified NPC
  # role (or one proper name with a known PC roster), with up to three questions.
  # Mentions, plans, quoted reports and mixed recipients retain model resolution.
  # The role vocabulary and the address forms live in the locale lexicon.

  @doc "NPC role or single proper name (with a PC roster) of a bounded question, or nil."
  def explicit_npc_question(text, opts \\ [])

  def explicit_npc_question(text, opts) when is_binary(text) do
    case quoted_npc_parts(text, opts) do
      {recipient, _speech, _clarification} -> recipient
      nil -> single_npc_question(text, opts)
    end
  end

  def explicit_npc_question(_, _), do: nil

  defp single_npc_question(text, opts) do
    text = String.trim(text)

    if single_question?(text) do
      captures = npc_question_captures(text, opts)

      if captures do
        recipient = lx().normalize_recipient(captures["recipient"])

        unless npc_role_is_pc?(recipient, Keyword.get(opts, :pc_names, [])), do: recipient
      end
    end
  end

  defp single_question?(text) do
    one_close? = length(String.split(text, "?")) == 2

    if lx().inverted_questions?(),
      do: one_close? and length(String.split(text, "¿")) == 2,
      else: one_close?
  end

  defp npc_question_captures(text, opts) do
    lex = lx()

    Regex.named_captures(lex.npc_question(), text) ||
      Regex.named_captures(lex.npc_vocative_question(), text) ||
      named_npc_captures(lex.npc_named_question(), text, opts) ||
      named_npc_captures(lex.npc_named_vocative_question(), text, opts)
  end

  defp named_npc_captures(regex, text, opts) do
    names = Keyword.get(opts, :pc_names, [])

    if is_list(names) and names != [] and Enum.all?(names, &is_binary/1),
      do: Regex.named_captures(regex, text)
  end

  defp npc_role_is_pc?(recipient, names) do
    recipient = npc_identity(recipient)

    names
    |> canonical_names()
    |> Enum.map(&npc_identity/1)
    |> Enum.flat_map(fn name ->
      first = name |> String.split() |> List.first()
      # Even an ambiguous short PC name must not become an NPC by accident.
      if first && String.length(first) >= 3, do: [name, first], else: [name]
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.any?(fn name ->
      Regex.match?(
        ~r/(?<![\p{L}\p{M}\p{N}_])#{Regex.escape(name)}(?![\p{L}\p{M}\p{N}_])/u,
        recipient
      )
    end)
  end

  defp npc_identity(name) do
    name
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace(lx().leading_article(), "")
  end

  # The quote closes before the passive wait. Nothing outside it can be treated
  # as speech, and each question must stay informative and share one recipient.
  # The reported preamble is spoken verbatim; it does not resolve its meaning.
  defp quoted_npc_parts(text, opts) do
    lex = lx()
    trimmed = String.trim(text)

    with %{} = parts <-
           Enum.find_value(lex.npc_quoted_speech(), &Regex.named_captures(&1, trimmed)),
         true <- parts["close"] in Map.get(lex.quote_pairs(), parts["open"], []),
         %{"recipient" => recipient} <-
           Regex.named_captures(lex.npc_address(), parts["prefix"]) ||
             named_npc_captures(lex.npc_named_address(), parts["prefix"], opts),
         true <- literal_npc_prefix?(parts["prefix"], recipient),
         false <- npc_role_is_pc?(recipient, Keyword.get(opts, :pc_names, [])),
         speech = String.trim(parts["speech"]),
         {questions, clarification?} <- speech_questions(speech, lex.inverted_questions?()),
         true <- Enum.all?(questions, &Regex.match?(lex.npc_speech_information(), &1)),
         tail =
           without_listening_permission(
             String.trim(parts["tail"]),
             Keyword.get(opts, :pc_names, [])
           ),
         true <- Regex.match?(lex.npc_speech_wait(), tail) do
      {lex.normalize_recipient(recipient), scrub("—" <> speech), clarification?}
    else
      _ -> nil
    end
  end

  # Questions of a quoted NPC speech and whether a recall preface opens it.
  # Spanish: the preface sits before the first `¿`. English: it opens the
  # first question ("When you said X, what did you mean?").
  defp speech_questions(speech, true) do
    with [[{start, _}] | _] = questions <- Regex.scan(~r/¿[^¿?]+\?/u, speech, return: :index),
         preface = binary_part(speech, 0, start),
         true <- preface == "" or Regex.match?(lx().npc_recall_preface(), preface),
         body = binary_part(speech, start, byte_size(speech) - start),
         true <- Regex.match?(~r/^(?:¿[^¿?]+\?\s*){1,3}$/u, body) do
      {Enum.map(questions, fn [{offset, size}] -> binary_part(speech, offset, size) end),
       preface != ""}
    else
      _ -> nil
    end
  end

  defp speech_questions(speech, false) do
    with true <- Regex.match?(lx().question_body(), speech),
         [first | rest] <- lx().question_item() |> Regex.scan(speech) |> List.flatten() do
      case Regex.run(lx().npc_recall_preface(), first, return: :index) do
        [{0, length} | _] ->
          {[binary_part(first, length, byte_size(first) - length) | rest], true}

        _ ->
          {[first | rest], false}
      end
    else
      _ -> nil
    end
  end

  @doc "Spoken words of a literal NPC question containing only speech and passive waiting, or nil."
  def literal_npc_speech(text, opts \\ [])

  def literal_npc_speech(text, opts) when is_binary(text) do
    case quoted_npc_parts(text, opts) do
      {_recipient, speech, _clarification} -> speech
      nil -> single_npc_speech(text, opts)
    end
  end

  def literal_npc_speech(_, _), do: nil

  @doc "A quoted clarification of earlier NPC speech, preserving its recipient and exact words."
  def literal_npc_clarification(text, opts \\ [])

  def literal_npc_clarification(text, opts) when is_binary(text) do
    case quoted_npc_parts(text, opts) do
      {recipient, speech, true} -> {recipient, speech}
      _ -> nil
    end
  end

  def literal_npc_clarification(_, _), do: nil

  defp single_npc_speech(text, opts) do
    text = String.trim(text)
    lex = lx()

    with recipient when is_binary(recipient) <- explicit_npc_question(text, opts),
         captures when is_map(captures) <- npc_question_captures(text, opts),
         {start, size} <- single_question_span(text, captures),
         true <- Regex.match?(lex.npc_speech_information(), binary_part(text, start, size)),
         prefix = binary_part(text, 0, start),
         true <- literal_npc_prefix?(prefix, captures["recipient"]),
         tail = binary_part(text, start + size, byte_size(text) - start - size),
         tail = Regex.replace(lex.question_tail_opener(), tail, ""),
         tail = without_listening_permission(tail, Keyword.get(opts, :pc_names, [])),
         true <- Regex.match?(lex.npc_speech_wait(), String.trim(tail)) do
      scrub("—" <> binary_part(text, start, size))
    else
      _ -> nil
    end
  end

  # Spanish questions are delimited by `¿…?`; the English address patterns
  # capture the question itself (`question`).
  defp single_question_span(text, captures) do
    if lx().inverted_questions?() do
      case Regex.run(~r/¿[^?]+\?/u, text, return: :index) do
        [span] -> span
        _ -> nil
      end
    else
      case captures do
        %{"question" => question} when question != "" ->
          case :binary.match(text, question) do
            {start, size} -> {start, size}
            :nomatch -> nil
          end

        _ ->
          nil
      end
    end
  end

  defp literal_npc_prefix?(prefix, recipient) do
    prefix = Regex.replace(lx().npc_speech_spatial(), String.trim(prefix), "")
    role = Regex.escape(recipient)

    Regex.match?(Regex.compile!(lx().npc_literal_prefix(role), "iu"), prefix) or
      Regex.match?(~r/^(?:[—–]\s*)?#{role}\s*,\s*$/iu, prefix)
  end

  defp without_listening_permission(tail, []), do: tail

  defp without_listening_permission(tail, names) do
    name = names |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    listeners = Regex.compile!(lx().listeners(name), "iu")
    Regex.replace(listeners, tail, "")
  end

  defp parse_vocative(vocative, pattern, owners) do
    case Regex.run(pattern, vocative) do
      [_, form, rest] ->
        name = owners[String.downcase(form)]

        case String.trim(rest) do
          "" ->
            [name]

          rest ->
            case Regex.run(lx().vocative_joiner(), rest) do
              [_, next] ->
                case parse_vocative(String.trim(next), pattern, owners) do
                  [] -> []
                  recipients -> [name | recipients]
                end

              _ ->
                []
            end
        end

      _ ->
        []
    end
  end

  defp names_in_question(_text, []), do: []

  defp names_in_question(text, registered) do
    owners =
      Map.new(
        for name <- registered,
            form <- name_forms([name], registered),
            do: {String.downcase(form), name}
      )

    owners =
      registered
      |> Enum.group_by(&first_name/1)
      |> Enum.reduce(owners, fn {first, names}, acc ->
        if length(names) > 1 and not Map.has_key?(acc, first) and
             Regex.match?(~r/^\p{L}[\p{L}'’\-]{2,}$/u, first),
           do: Map.put(acc, first, :ambiguous),
           else: acc
      end)

    alternatives =
      owners
      |> Map.keys()
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map_join("|", &Regex.escape/1)

    pattern = Regex.compile!("(?<![\\p{L}\\p{N}_])(?:#{alternatives})(?![\\p{L}\\p{N}_])", "iu")
    open_question = lx().name_in_open_question()

    Regex.scan(pattern, text, return: :index)
    |> Enum.filter(fn [{offset, size}] ->
      prefix = binary_part(text, 0, offset)
      suffix = binary_part(text, offset + size, byte_size(text) - offset - size)

      Regex.match?(~r/^\s*[,:]/u, suffix) or
        Regex.match?(open_question, prefix) or
        Regex.match?(~r/^[^?]{0,60}\?/u, suffix)
    end)
    |> Enum.map(fn [{offset, size}] ->
      owners[String.downcase(binary_part(text, offset, size))]
    end)
    |> Enum.uniq()
  end

  defp question_to_pc?(text) do
    punctuated? =
      if lx().inverted_questions?(),
        do: String.contains?(text, "¿") or String.ends_with?(text, "?"),
        else: String.contains?(text, "?")

    punctuated? or Enum.any?(lx().question_cues(), &Regex.match?(&1, text))
  end

  defp maybe_strip_pc_world_leaks(text, actor, names)
       when is_binary(actor) and actor not in ["", "dm", "turnmaster", "system"] do
    text
    |> split_clauses()
    |> Enum.map(&trim_pc_world_leak(&1, names))
    |> Enum.reject(&(&1 == ""))
    |> join_clauses()
  end

  defp maybe_strip_pc_world_leaks(text, _actor, _names), do: text

  # Exploration + human at the table: an AI PC must propose, not finish the
  # job (open the scroll, pick the item, walk off). Combat is untouched.
  defp maybe_strip_solo_exec(text, actor, opts)
       when is_binary(actor) and actor not in ["", "dm", "turnmaster", "system"] do
    if Keyword.get(opts, :wait_for_human, false) do
      text
      |> split_clauses()
      |> Enum.map(&trim_solo_exec/1)
      |> Enum.reject(&(&1 == ""))
      |> join_clauses()
    else
      text
    end
  end

  defp maybe_strip_solo_exec(text, _, _), do: text

  defp trim_solo_exec(clause) do
    case earliest_index(clause, [lx().solo_exec()]) do
      nil -> clause
      idx -> keep_prefix(clause, idx)
    end
  end

  defp trim_pc_world_leak(clause, names) do
    cond do
      idx = time_skip_index(clause) ->
        keep_prefix(clause, idx)

      idx = npc_voice_index(clause, names) ->
        keep_prefix(clause, idx)

      true ->
        clause
    end
  end

  defp time_skip_index(clause) do
    earliest_index(clause, lx().time_skips())
  end

  defp npc_voice_index(clause, names) do
    if own_dialogue?(clause) do
      nil
    else
      named_idx = named_other_index(clause, names)
      role_idx = earliest_index(clause, [lx().npc_voice_colon(), lx().npc_role_speaks()])
      relative_idx = npc_role_relative_index(clause)
      attribution_idx = npc_attribution_index(clause, names)

      [named_idx, role_idx, relative_idx, attribution_idx]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)
    end
  end

  # Addressing the NPC is the PC's action; the NPC's immediate relative reply
  # belongs to the DM. Cut from "que responde", retaining the role recipient.
  defp npc_role_relative_index(clause) do
    case Regex.run(lx().npc_role_relative_speaks(), clause, return: :index, capture: ["relative"]) do
      [{index, _length}] -> index
      _ -> nil
    end
  end

  # "Me dice la hora/la verdad" is an observation, not an NPC speaking.
  # Resolve actual registered speakers first; otherwise require a known role
  # or an explicit quotation/dash attribution before cutting the PC's clause.
  defp npc_attribution_index(clause, names) do
    lx().npc_attributions()
    |> Enum.flat_map(&Regex.scan(&1, clause, return: :index))
    |> Enum.sort()
    |> Enum.find_value(fn [{idx, _}, {speaker_idx, _} = capture] ->
      speaker = binary_part(clause, speaker_idx, byte_size(clause) - speaker_idx)
      prefix = binary_part(clause, 0, idx) |> String.trim_trailing()

      attribution? =
        matching_name(speaker, names.all) != nil or Regex.match?(lx().npc_role_name(), speaker) or
          Regex.match?(~r/[»”"](?:\s*[,—-])?$/u, prefix) or
          String.ends_with?(prefix, ["—", "-"])

      if attribution? and foreign_speaker?(clause, [capture], names), do: idx
    end)
  end

  defp own_dialogue?(clause) do
    lex = lx()

    Regex.match?(lex.own_speech(), clause) and not Regex.match?(lex.npc_speech_verbs(), clause) and
      not Regex.match?(lex.npc_voice_colon(), clause) and
      not Regex.match?(lex.npc_role_speaks(), clause) and
      not Regex.match?(lex.npc_role_relative_speaks(), clause)
  end

  defp named_other_index(clause, names) do
    verb_name =
      case Regex.run(lx().npc_named(), clause, return: :index) do
        [{idx, _} | rest] ->
          if foreign_speaker?(clause, rest, names), do: idx

        _ ->
          nil
      end

    name_verb =
      case Regex.run(lx().npc_name_speaks(), clause, return: :index) do
        [{idx, _} | rest] ->
          if foreign_speaker?(clause, rest, names), do: idx

        _ ->
          nil
      end

    [verb_name, name_verb]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp foreign_speaker?(clause, [{cidx, _clen} | _], names) do
    speaker = binary_part(clause, cidx, byte_size(clause) - cidx)

    case matching_name(speaker, names.all) do
      nil ->
        not Enum.any?(names.ambiguous, fn name ->
          Regex.match?(Regex.compile!("^#{Regex.escape(name)}\\s*(?=$|[,.:：—])", "iu"), speaker)
        end)

      name ->
        not same_name?(name, names.own)
    end
  end

  defp foreign_speaker?(_, _, _), do: false

  defp earliest_index(text, regexes) do
    regexes
    |> Enum.map(fn re ->
      case Regex.run(re, text, return: :index) do
        [{idx, _} | _] -> idx
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp keep_prefix(_clause, 0), do: ""

  defp keep_prefix(clause, idx) when idx > 0 do
    clause
    |> binary_part(0, idx)
    |> String.replace(lx().trailing_conj(), "")
    |> String.trim()
  end

  # Quote-aware sentence split: do not break on `.!?` inside «…» / "…".
  # A 80-word run-on without a period stays one clause so the attributor
  # cut can still keep the PC prefix.
  defp split_clauses(text) do
    {chunks, current, _mode} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", :out}, &clause_grapheme/2)

    (Enum.reverse(chunks) ++ [current])
    |> split_after_closed_quotes(lx().closed_quote_boundary())
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_after_closed_quotes(chunks, nil), do: chunks

  defp split_after_closed_quotes(chunks, boundary),
    do: Enum.flat_map(chunks, &Regex.split(boundary, &1))

  defp clause_grapheme(g, {acc, cur, :out}) do
    cond do
      open_quote?(g) -> {acc, cur <> g, :in}
      sentence_end?(g) -> {acc, cur <> g, :end}
      true -> {acc, cur <> g, :out}
    end
  end

  defp clause_grapheme(g, {acc, cur, :in}) do
    if close_quote?(g), do: {acc, cur <> g, :out}, else: {acc, cur <> g, :in}
  end

  defp clause_grapheme(g, {acc, cur, :end}) do
    if whitespace?(g) do
      {[cur | acc], "", :out}
    else
      {acc, cur <> g, :out}
    end
  end

  defp open_quote?(g), do: g in ["\"", "«", "“"]
  defp close_quote?(g), do: g in ["\"", "»", "”"]
  defp sentence_end?(g), do: g in [".", "!", "?", "…"]
  defp whitespace?(g), do: Regex.match?(~r/^\s$/u, g)

  defp join_clauses([]), do: ""
  defp join_clauses(clauses), do: Enum.join(clauses, " ")
end
