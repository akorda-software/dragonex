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
  """

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
    text
    |> strip_leading_actor_tags()
    |> strip_inline_actor_tags()
    |> strip_leading_turn_header()
    |> strip_inline_history_headers()
    |> unwrap_markdown_emphasis()
    |> strip_orphan_emphasis()
    |> strip_leading_self_name(actor)
    |> strip_fused_roll_label(actor)
    |> strip_leaked_tool_tokens()
    |> drop_combat_recap_blocks()
    |> drop_inline_stats()
    |> cleanup_after_stat_strip()
    |> drop_narrated_dice_syntax()
    |> drop_narrated_tool_invocations()
    |> drop_engine_meta_phrases()
    |> maybe_strip_puppet_clauses(actor, Keyword.get(opts, :pc_names, []))
    |> maybe_strip_pc_world_leaks(actor)
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
    |> String.replace(~r/\[→\s*[^\]\n]{1,40}\s+decide\]\s*:?\s*/u, "")
  end

  # Dice-card leak: the model (or a glued who-chip) writes "Lyrachequeo de
  # Inteligencia". Leading self-name already covers the start of a beat;
  # this catches the same fuse mid-prose. ThaneSe/LyraSe stays in
  # strip_leading_self_name.
  defp strip_fused_roll_label(text, actor) when is_binary(actor) and actor != "" do
    escaped = Regex.escape(actor)

    case Regex.compile("#{escaped}(?=chequeo|ataque|tirada|salvaci[oó]n)", "iu") do
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
  # surrounding sentence and just drop the offending pattern. Covered forms:
  #   * "6/13 pg", "10/10 hp"            — current/max (the X/Y form)
  #   * "(13 → 6/13 pg)" envelopes
  #   * "le quedan 7 pg", "le quedan X"
  #   * "CA 15", "Clase de Armadura 13"   — armor class
  #   * "7 pg", "10 hp", "p.g."           — bare current HP
  #   * "7 puntos de golpe/vida"
  #   * "1 de los 7 puntos de vida originales"
  # Conservative on bare numbers: a digit only counts as HP when followed
  # explicitly by pg/hp/p.g./puntos de (golpe|vida), so "15 de oro" or "3
  # puertas" are left alone. "CA" is matched case-sensitively (always uppercase
  # in stat blocks) so the Spanish syllable "ca" inside other words is safe.
  @inline_hp_xy ~r/\b\d{1,4}\s*\/\s*\d{1,4}\s*(?:pg|hp|p\.g\.|puntos de (?:golpe|vida))\b/i
  # Bare HP: both forms — "13 pg" (number-first) and "HP 13" (label-first).
  @inline_bare_hp ~r/\b(?:\d{1,4}\s*(?:pg|hp|p\.g\.)|(?:pg|hp)\s*\d{1,4})\b/i
  @inline_puntos ~r/\b\d{1,4}\s*puntos de (?:golpe|vida)\b/i
  @inline_of_total ~r/\b\d{1,4}\s*de los\s*\d{1,4}\s*puntos de (?:golpe|vida)(?:\s*originales)?\b/i
  # Armor class: both Spanish (CA) and English (AC) — the model leaks stats in
  # either language.
  @inline_ca ~r/\b(?:CA|AC)\s*(?::|=|es|de)?\s*\d{1,4}\b/
  @inline_ca_long ~r/\bclase de armadura\s*(?::|=|es|de)?\s*\d{1,4}\b/i
  # A whole parenthesised stat block the model sometimes drops into prose:
  # "(AC 12, HP 13, daño 1d4+2 con tridente)" — drop the entire parenthesis.
  @stats_parens ~r/\([^)]*(?:\b(?:CA|AC|HP|PG|pg)\b\s*(?:[:=]|\s*es\s*|\s*de\s*)?\s*\d|\d{1,4}\s*\/\s*\d{1,4})[^)]*\)/i

  defp drop_inline_stats(text) do
    text
    |> String.replace(@stats_parens, "")
    |> String.replace(@inline_of_total, "")
    |> String.replace(@inline_hp_xy, "")
    |> String.replace(@inline_puntos, "")
    |> String.replace(@inline_bare_hp, "")
    |> String.replace(@inline_ca_long, "")
    |> String.replace(@inline_ca, "")
    |> String.replace(~r/\(\s*\d{1,4}\s*→\s*\)/, "")
    |> String.replace(~r/\ble quedan\b\s*\/?\s*(?:pg|hp)?\.?/i, "")
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
    |> String.replace(~r/\b\d{1,4}\s+de\s*(?:\*\*)?\s*(?=\*\*|[.,;:!?…]|$)/u, "")
    # Dangling "queda con ." / "cae a ," / "recuperado por completo ."
    |> String.replace(
      ~r/\b(queda con|cae a|baja a|tiene|con|por completo)\s*(?=[.,;:!?…]|$)/iu,
      ""
    )
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
    Regex.match?(
      ~r/\b(?:ataque|ataca|chequeo|tirada|da[nñ]o|salvaci[oó]n|iniciativa)\b/i,
      line
    )
  end

  # These appear when the model recaps HP per combatant. Drop the whole block:
  # the header line + any following list of "<name>: ... pg" / "<name> (X/Y)".
  # Accept markdown bold on either side of the colon: `**Estado del Combate:**`,
  # `**Estado del Combate**:`, `Estado del Combate:`.
  @recap_headers ~r/^\s*\*{0,2}\s*(?:Estado del (?:Combate|Batalla)|Situación(?: actual)?|Resumen(?: del combate)?|Combate|Stats?|Batalla)\s*\*{0,2}\s*[:：]\s*\*{0,2}\s*$/i

  defp drop_combat_recap_blocks(text) do
    lines = String.split(text, "\n")

    {dropped, kept} =
      Enum.reduce(lines, {false, []}, fn line, {in_block, acc} ->
        cond do
          # Header opens a recap block — start dropping.
          Regex.match?(@recap_headers, line) ->
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
      Regex.match?(~r/\d{1,4}\s*\/\s*\d{1,4}\s*(?:pg|hp)/i, trimmed) or
        Regex.match?(~r/\bCA\s*\d+/i, trimmed)

    starts_with_bullet? and has_stats?
  end

  # Engine meta phrases that leak internal vocabulary into the prose:
  # "el sistema resuelve...", "el motor decide...", "la herramienta devuelve..."
  # Plus DM fourth-wall breaks: "la escena se resetea", "lo materializo en el
  # mundo para que sea oficial", "como DM yo...", "para que conste/sea oficial".
  # These break immersion — the model is describing its own mechanics or
  # narrating the engine instead of the fiction.
  defp drop_engine_meta_phrases(text) do
    text
    |> String.replace(
      ~r/el (?:sistema|motor|framework|backend)\s+(?:resuelve|decide|procesa|devuelve)[^.]*\./i,
      ""
    )
    |> String.replace(
      ~r/la (?:herramienta|tool|función)\s+(?:resuelve|devuelve|procesa)[^.]*\./i,
      ""
    )
    |> String.replace(~r/la escena se resetea[^.]*\./i, "")
    |> String.replace(~r/\blo materializo(?:\s+en el mundo)?[^.]*\./i, "")
    |> String.replace(~r/para que (?:sea oficial|conste|quede registrado)[^.]*\./i, "")
    |> String.replace(~r/(?:yo )?como DM[^.]*\./i, "")
    |> String.replace(~r/\b[Ee]l [ée]xito del (?:chequeo|estudio|examen)[^.]*\./u, "")
  end

  # Tool calls the model WRITES into the prose instead of emitting as real
  # tool_calls. Two shapes appear in the wild:
  #   * function-like:  "establish_fact("...")", "spawn_monster("goblin","g1")"
  #   * bracketed tags: "[Establecer hecho: ...]", "[Hecho: ...]", "[Spawn: ...]"
  # Both are noise the player should never see. The real tool call (if any) was
  # emitted separately and resolved by the engine; this is the model narrating
  # the invocation as text.
  @narrated_tool_calls ~r/\b(?:establish_fact|spawn_monster|set_scene|make_attack|cast_spell|roll_initiative|ability_check|end_combat|level_up|apply_condition|remove_condition|heal|make_death_save|short_rest|long_rest)\s*\([^)]*\)/i
  @narrated_tool_brackets ~r/\[(?:establecer )?(?:hecho|spawn|invocaci[oó]n|narraci[oó]n|acci[oó]n)\s*[:=][^\]]*\]/i

  defp drop_narrated_tool_invocations(text) do
    text
    |> String.replace(@narrated_tool_calls, "")
    |> String.replace(@narrated_tool_brackets, "")
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

  @puppet_action_verbs ~w(
    ataca ataco atacar ataque
    lanza lanzo lanzar
    conjura conjuro conjurar
    golpea golpeo golpear
    dispara disparo disparar
    desenvaina desenvainar desenfunda desenfundar
    tensa tensar apunta apuntar
    prepara preparar
    carga cargo cargar
    salta salto saltar
    corre correr
    persigue perseguir
    hechiza hechizar
    arremete arremeter
    embiste embestir
    invoca invocar
    avanza avanzar
    sube subir baja bajar
    entra entrar sale salir
    mueve mover
    abre abrir cierra cerrar
    empuja empujar tira tirar
    agarra coge toma deja
    gira voltea
    examina examinar inspecciona inspeccionar
    busca buscar registra estudia
    dice hablar habla
    grita susurrar susurra
    pregunta preguntar responde responder exclama replica
    aprovecha aprovechar
    se_abalanza se_lanza se_agacha se_acerca se_incorpora se_prepara
  )

  @doc """
  True when `text` describes a PC performing a proactive action (rule 14 leak).
  """
  @spec dm_puppets_pc?(String.t(), [String.t()]) :: boolean()
  def dm_puppets_pc?(text, pc_names)
      when is_binary(text) and is_list(pc_names) do
    pc_names != [] and Regex.match?(puppet_anywhere_pattern(pc_names), text)
  end

  def dm_puppets_pc?(_, _), do: false

  @doc """
  Drop clauses that start with `<PC> <action-verb>`. Passive state
  (`Lyra está herida`, `Lyra cae herida`) is kept — those verbs are not
  in the action list. A mention mid-clause (`junto a Lyra, el tabernero
  abre`) is also kept.
  """
  @spec strip_puppet_clauses(String.t(), [String.t()]) :: String.t()
  def strip_puppet_clauses(text, pc_names)
      when is_binary(text) and is_list(pc_names) do
    if pc_names == [] do
      text
    else
      re = puppet_subject_pattern(pc_names)

      text
      |> split_clauses()
      |> Enum.reject(&Regex.match?(re, &1))
      |> join_clauses()
    end
  end

  def strip_puppet_clauses(text, _), do: text

  defp maybe_strip_puppet_clauses(text, "dm", pc_names) when is_list(pc_names) do
    strip_puppet_clauses(text, pc_names)
  end

  defp maybe_strip_puppet_clauses(text, _actor, _pc_names), do: text

  defp puppet_verb_alt do
    @puppet_action_verbs
    |> Enum.map(fn v -> v |> String.replace("_", "\\s+") |> then(&"(?:#{&1})") end)
    |> Enum.join("|")
  end

  defp puppet_anywhere_pattern(pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    pattern = "(?:\\b#{names_alt}\\b)[^.!?]{0,80}\\b(?:#{puppet_verb_alt()})\\b"

    case Regex.compile(pattern, "i") do
      {:ok, re} -> re
      {:error, _} -> ~r/^$/
    end
  end

  defp puppet_subject_pattern(pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    pattern =
      "^\\s*(?:—\\s*)?(?:\\*+\\s*)?(?:#{names_alt})(?:\\*+\\s*)?\\b[^.!?]{0,80}\\b(?:#{puppet_verb_alt()})\\b"

    case Regex.compile(pattern, "iu") do
      {:ok, re} -> re
      {:error, _} -> ~r/^$/
    end
  end

  @time_skip ~r/\b(?:media hora|un rato|unos minutos|unas horas|varios d[ií]as|un par de horas)\s+despu[eé]s\b/iu
  @time_skip_later ~r/\b(?:horas?|d[ií]as?|minutos?)\s+m[aá]s tarde\b/iu
  @time_skip_cabo ~r/\bal cabo de\s+(?:un rato|una hora|unas horas|unos minutos)\b/iu
  @time_skip_next ~r/\bal (?:d[ií]a|amanecer|anochecer) siguiente\b/iu

  @npc_speech_verbs ~r/\b(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|grita|gritando|susurra|chilla|maldice)\b/iu
  @npc_attr ~r/\b(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|grita|gritando|susurra)\s+(?:el|la|los|las)\s+\w+/iu
  @npc_named ~r/\b(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|grita|gritando|susurra)\s+([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)/u
  @npc_name_speaks ~r/\b([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)\s+(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|baja la voz|grita|gritando|susurra|maldice)\s*:/u
  @npc_voice_colon ~r/\b(?:baja la voz|dice con voz|contesta|replica en voz|grita|gritando|chilla|a[uú]lla|maldice|susurra|vocifera)\s*:/iu
  @npc_role_speaks ~r/\b(?:el|la)\s+(?:posadero|posadera|tabernero|tabernera|mesonero|encargado|encapuchado|emisario|anciano|anciana|enano|enana)\b.{0,120}[—«"“]/iu
  @own_speech ~r/\b(?:pregunto|digo|respondo|exclamo|añado|replico)\b/iu
  @trailing_conj ~r/\s+(?:y|e|pero|mientras|cuando|luego)\s*$/iu

  @doc """
  Who a DM beat is asking, if anyone.

  Returns `{:named, "Thane"}` when a PC name sits in the question,
  `:question` when the prose is a question to "you" / "qué hace" / ends
  in `¿…?` without a name, or `nil` when it is not a prompt to a PC.
  """
  @spec addressed_pc(String.t(), [String.t()]) :: {:named, String.t()} | :question | nil
  def addressed_pc(text, names) when is_binary(text) and is_list(names) do
    cleaned =
      text
      |> strip_inline_actor_tags()
      |> strip_inline_history_headers()
      |> String.trim()

    names = Enum.filter(names, &(is_binary(&1) and &1 not in ["", "dm"]))

    cond do
      cleaned == "" ->
        nil

      not question_to_pc?(cleaned) ->
        nil

      name = named_in_question(cleaned, names) ->
        {:named, name}

      true ->
        :question
    end
  end

  def addressed_pc(_, _), do: nil

  defp named_in_question(text, names) do
    Enum.find(names, fn name ->
      escaped = Regex.escape(name)

      Regex.match?(~r/#{escaped}\s*[,:]/u, text) or
        Regex.match?(~r/¿[^?]{0,100}#{escaped}/iu, text) or
        Regex.match?(~r/#{escaped}[^?]{0,60}\?/iu, text)
    end)
  end

  defp question_to_pc?(text) do
    String.contains?(text, "¿") or String.ends_with?(text, "?") or
      Regex.match?(~r/\bante ti\b/iu, text) or
      Regex.match?(~r/\bpara ti\b/iu, text) or
      Regex.match?(~r/¿?\s*qué hace(?:s|is|n)?\b/iu, text) or
      Regex.match?(~r/\btú\b/u, text) or
      Regex.match?(~r/\bsi quieres\b/iu, text) or
      Regex.match?(~r/\bte toca\b/iu, text) or
      Regex.match?(~r/\bes tu (?:turno|decisi[oó]n)\b/iu, text)
  end

  defp maybe_strip_pc_world_leaks(text, actor)
       when is_binary(actor) and actor not in ["", "dm", "turnmaster", "system"] do
    text
    |> split_clauses()
    |> Enum.map(&trim_pc_world_leak(&1, actor))
    |> Enum.reject(&(&1 == ""))
    |> join_clauses()
  end

  defp maybe_strip_pc_world_leaks(text, _actor), do: text

  # Exploration + human at the table: an AI PC must propose, not finish the
  # job (open the scroll, pick the item, walk off). Combat is untouched.
  @solo_exec ~r/\b(?:desliza la uña|quiebra|despliega el pergamino|rompe el lacre|recoge (?:la|el)|coge (?:la|el)|toma la pluma|lanza un|conjura |dispara un|camina hacia|se encamina|desaparece en|lee en voz alta|una hora andando)\b/iu

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
    case earliest_index(clause, [@solo_exec]) do
      nil -> clause
      idx -> keep_prefix(clause, idx)
    end
  end

  defp trim_pc_world_leak(clause, actor) do
    cond do
      idx = time_skip_index(clause) ->
        keep_prefix(clause, idx)

      idx = npc_voice_index(clause, actor) ->
        keep_prefix(clause, idx)

      true ->
        clause
    end
  end

  defp time_skip_index(clause) do
    earliest_index(clause, [@time_skip, @time_skip_later, @time_skip_cabo, @time_skip_next])
  end

  defp npc_voice_index(clause, actor) do
    if own_dialogue?(clause) do
      nil
    else
      named_idx = named_other_index(clause, actor)
      role_idx = earliest_index(clause, [@npc_voice_colon, @npc_role_speaks, @npc_attr])

      [named_idx, role_idx]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)
    end
  end

  defp own_dialogue?(clause) do
    Regex.match?(@own_speech, clause) and not Regex.match?(@npc_speech_verbs, clause) and
      not Regex.match?(@npc_voice_colon, clause) and not Regex.match?(@npc_role_speaks, clause)
  end

  defp named_other_index(clause, actor) do
    actor_l = String.downcase(actor)

    verb_name =
      case Regex.run(@npc_named, clause, return: :index) do
        [{idx, _} | rest] ->
          name = named_capture(clause, rest)
          if name && String.downcase(name) != actor_l, do: idx

        _ ->
          nil
      end

    name_verb =
      case Regex.run(@npc_name_speaks, clause, return: :index) do
        [{idx, _} | rest] ->
          name = named_capture(clause, rest)
          if name && String.downcase(name) != actor_l, do: idx

        _ ->
          nil
      end

    [verb_name, name_verb]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp named_capture(clause, [{cidx, clen} | _]) do
    binary_part(clause, cidx, clen)
  end

  defp named_capture(_, _), do: nil

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
    |> String.replace(@trailing_conj, "")
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
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

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
