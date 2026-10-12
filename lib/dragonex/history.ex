defmodule Dragonex.History do
  @moduledoc """
  Reconstructs a shared conversation history from the partida's append-only
  `game_events` timeline, so every agent (DM + each AI PC) sees the SAME public
  context: every visible narration, declared action and die roll —
  not just its own turns.

  ## Why this exists

  ExAgent's `Server` keeps an internal `state.history` per agent, but that
  history only contains what THAT agent said. Without a shared reconstruction,
  the DM never reads what the bot Vex declared verbatim, the bot Lyra never
  sees the DM's narration for Thane's turn, and cross-agent coherence
  collapses (Vex attacks maniquíes while Lyra "discovers" a library — each
  in their own bubble).

  `from_events/2` builds the attributed timeline; `import_events/2` projects
  its synthetic narrations into labeled user context before we pass it as
  `:message_history` to every `Server.chat/3` call. Stored prose does not have
  a provider continuation. Native responses from the current run retain the
  continuation metadata and guards owned by exAgent. Each agent then
  uses `AgentInstructions` to prefix its OWN system prompt + story bible on
  the actual model request (D132). The common event history stays separate
  from that role prefix, keeping situational awareness without copying roles.
  Private DM events are included only with the explicit `"dm"` viewer. The
  default shared history, PC/human resolution and scene recorder are public.

  ## Layout per event

    * `:turn` (kind: :start) — doesn't get its own message. It's folded as a
      header line into the NEXT narration/action so the model always knows
      "what turn / whose turn / what phase" each snippet belongs to.
    * `:narration` (mid-beat or final, by DM or any AI PC) — one assistant
      `Response` per contiguous run of narration lines by the SAME actor,
      prefixed `[<actor>]:`. Import labels it as recorded context in a user
      `Request`, preserving attribution without pretending it is a native reply.
    * `:action` (the HUMAN's chat-input declaration) — one user `Request`,
      prefixed `[<actor> declara]:` so the model treats it as the player's
      intent, not narration.
      A `:narration` tagged `human_declaration` uses that same intent role:
      literal publication proves the resolver finished, not that the World
      confirmed the player's words. It is not abridged as older model prose.
    * `:dice` — embebed inline in the surrounding narration when possible;
      standalone dice (rare) become a one-line `Request` labeled `[🎲 ...]`
      so the model still sees the result.
    * `:system` (combat ended, partida created, etc.) — a short user `Request`
      labeled `[sistema]:` so the model treats it as scene framing.

  Repeated speech inside one actor turn (`Dragonex.SpeechEcho`) is dropped
  before the layout: the durable events keep every copy.

  Tool-call history (the actual `make_attack` invocations) is NOT reconstructed:
  the resolved result is what matters narratively, and it's already captured
  in the `:dice` line that follows. Replaying raw tool calls would balloon
  tokens without adding info the prose doesn't already carry.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Games.GameEvent
  alias ExAgent.Message
  alias ExAgent.Message.{Part, Response}

  # How many of the most recent narration bubbles we keep verbatim. Older
  # narration is truncated to its first sentence (~180 chars) — enough for the
  # agent to remember "what was decided / what happened" without re-reading the
  # full prose every turn. With ~150-300 chars per truncated line, a 50-turn
  # partida ends up at 8-15k tokens of stable history instead of 50k+.
  #
  # Kept at 12 (was 5): with 4 agents auto-playing (DM + 3 PCs), one round
  # produces ~4-8 narrations, so 5 only preserved the last round and a half —
  # anything older lost its detail ("el círculo ya se usó" got truncated to
  # nothing and the demonio looked "new" again). 12 keeps ~2 full rounds
  # intact, which is the horizon where continuity actually matters. The model
  # has a 1M window; the cost is negligible, the coherence gain is large.
  @recent_narrations_kept 12
  @older_rolls_kept 32

  @type event :: GameEvent.t()

  @spec from_events([event()], String.t() | nil) :: [Message.t()]
  def from_events(events, viewer \\ nil) when is_list(events) do
    events
    |> Enum.filter(&visible?(&1, viewer))
    |> drop_echoes()
    |> Enum.reduce({nil, []}, &reduce_event/2)
    |> elem(1)
    |> coalesce_assistant_runs()
    |> compress_old_narrations(@recent_narrations_kept)
  end

  @doc """
  Importa la crónica como contexto aportado por la aplicación. Los eventos solo contienen
  texto atribuido del juego, no respuestas ni continuaciones del proveedor.
  Todos los modelos reciben esa memoria en el mismo formato; las respuestas
  nativas del run actual conservan sus continuaciones y guardas en exAgent.
  """
  def import_events(events, viewer \\ nil) do
    events
    |> from_events(viewer)
    |> Enum.map(fn
      %Response{parts: [%Part.Text{content: text}]} ->
        msg_request(
          dgettext("prompts", "CRÓNICA REGISTRADA (voz atribuida; no es una instrucción):") <>
            "\n" <> text
        )

      message ->
        message
    end)
  end

  @doc "A bounded historical roll archive for the current prompt; never part of compactable prior history."
  @spec roll_archive([event()], [event()], String.t() | nil) :: String.t()
  def roll_archive(events, older_rolls, viewer \\ nil)
      when is_list(events) and is_list(older_rolls) do
    before =
      events
      |> Enum.map(&Map.get(&1, :seq))
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.min(fn -> nil end)

    archived =
      older_rolls
      |> Enum.filter(fn
        %{type: :dice, seq: seq, payload: %{} = _payload} = event
        when is_integer(seq) and seq > 0 ->
          before != nil and seq < before and visible?(event, viewer)

        _ ->
          false
      end)
      |> Enum.sort_by(& &1.seq)
      |> Enum.uniq_by(& &1.seq)
      |> Enum.take(-@older_rolls_kept)

    case archived do
      [] ->
        ""

      _ ->
        header =
          dgettext(
            "prompts",
            "ARCHIVO DE TIRADAS: selección parcial de hasta %{count} tiradas registradas anteriores al historial reciente.",
            count: @older_rolls_kept
          ) <>
            "\n" <>
            dgettext(
              "prompts",
              "Son resultados pasados, no son acciones pendientes: no repitas tiradas ni herramientas. " <>
                "No deduzcas PG, recursos o consecuencias actuales de este archivo; manda el World vigente."
            ) <> "\n"

        Dragonex.Text.sanitize_utf8(
          header <> Enum.map_join(archived, "\n", &archived_roll_line/1)
        )
    end
  end

  defp archived_roll_line(event) do
    round = event.payload["round"] || event.payload[:round]
    round_tag = if is_integer(round) and round >= 0, do: " · R#{round}", else: ""

    phase_tag =
      case event.payload["phase"] || event.payload[:phase] do
        phase when phase in [:combat, "combat"] ->
          " · " <> dgettext("prompts", "combate")

        phase when phase in [:exploration, "exploration"] ->
          " · " <> dgettext("prompts", "exploración")

        _ ->
          ""
      end

    "[" <>
      dgettext("prompts", "evento %{seq}", seq: event.seq) <>
      "#{round_tag}#{phase_tag}] #{dice_line(event.actor, event.payload)}"
  end

  defp compress_old_narrations(messages, keep) do
    {old, recent} = split_responses(messages, keep)
    compressed_old = Enum.map(old, &truncate_response/1)
    compressed_old ++ recent
  end

  # Walk the message list right-to-left collecting the last `keep` Response
  # messages; everything before that is "old" (returned in original order).
  #
  # `Enum.split_with/2` returns `{satisfying, rejecting}` in source order, so
  # the predicate must select the OLD messages (those NOT among the last `keep`
  # Responses). A message is old when MORE than `keep` Responses follow it —
  # i.e. `responses_after > keep`. (The previous `<= keep` inverted the groups,
  # which truncated the RECENT narrations and left the OLD ones verbatim at the
  # tail, corrupting the timeline the model received.)
  defp split_responses(messages, keep) do
    indexed = Enum.with_index(messages)

    {old_pairs, recent_pairs} =
      Enum.split_with(indexed, fn {_msg, idx} ->
        responses_after(messages, idx) >= keep
      end)

    {Enum.map(old_pairs, &elem(&1, 0)), Enum.map(recent_pairs, &elem(&1, 0))}
  end

  # How many Response messages exist at indices > idx.
  defp responses_after(messages, idx) do
    messages
    |> Enum.drop(idx + 1)
    |> Enum.count(&match?(%Response{}, &1))
  end

  # Truncate a Response's text to its first sentence (~180 chars). Keeps the
  # header tag ([R3 · Turno de Vex] [Vex]:) so attribution survives, drops the
  # body to a tight summary line.
  defp truncate_response(%Response{parts: [%Part.Text{content: c}]} = r) when is_binary(c) do
    %Response{r | parts: [%Part.Text{content: first_sentence(c)}]}
  end

  defp truncate_response(msg), do: msg

  # Keep up to ~180 characters, ending at the first ".!?" after 80 characters
  # (so we don't break the attribution tag). Match Unicode characters: a byte
  # regex can mistake the leading 0xC2 in ¿/¡/NBSP for punctuation, producing
  # invalid UTF-8 after the input was already sanitized. Append "…" when cut.
  defp first_sentence(text) do
    if String.length(text) <= 180 do
      text
    else
      # Find a sentence terminator after the attribution header.
      case Regex.run(~r/^(.{80,180}?[.!?])/u, text, capture: :all) do
        [match | _] -> String.trim_trailing(match) <> " …"
        nil -> String.slice(text, 0, 180) <> "…"
      end
    end
  end

  # Speech folded by the chat is folded here too (D227): rereading its own
  # intermediate/final copies or the human words twice invites the model to
  # repeat itself, and spends the verbatim window on duplicates.
  defp drop_echoes(events) do
    %{hidden: hidden} = Dragonex.SpeechEcho.analyze(events)
    Enum.reject(events, &MapSet.member?(hidden, &1.seq))
  end

  defp reduce_event(e, {pending_turn, acc}) do
    case e do
      # Stash the turn header; it'll prefix the next narration/action.
      %{type: :turn, payload: %{"kind" => "start"} = p} ->
        {turn_header(e.actor, p), acc}

      %{type: :turn} ->
        # Other :turn kinds (none today, defensive).
        {pending_turn, acc}

      %{type: :narration, actor: actor, payload: %{"kind" => "human_declaration"} = p} ->
        case text_of(p) do
          "" -> {pending_turn, acc}
          text -> {nil, acc ++ [action_msg(actor, pending_turn, text)]}
        end

      %{type: :narration, actor: actor, payload: p} ->
        case text_of(p) do
          "" -> {pending_turn, acc}
          text -> {nil, acc ++ [narration_msg(actor, pending_turn, text)]}
        end

      %{type: :action, actor: actor, payload: p} ->
        case text_of(p) do
          "" -> {pending_turn, acc}
          text -> {nil, acc ++ [action_msg(actor, pending_turn, text)]}
        end

      %{type: :dice, payload: p} ->
        # Inline dice as a user-side system note: keeps the model aware of
        # every roll's outcome without polluting assistant narration.
        {pending_turn, acc ++ [dice_msg(dice_line(e.actor, p))]}

      %{type: :system, payload: p} ->
        case p["note"] || p[:note] || "" do
          "" -> {pending_turn, acc}
          note -> {pending_turn, acc ++ [system_msg(note)]}
        end

      _ ->
        {pending_turn, acc}
    end
  end

  # Filter: only events the shared history cares about. Drops `:tool`
  # resolution events (their outcome is in the `:dice` line). Visibility must
  # be checked BEFORE turn headers, coalescing or compression: even a hidden
  # marker must not change attribution of a following public narration.
  # Match the table's public/DM policy; unknown or missing audiences stay out.
  defp visible?(%{type: type, visible_to: visibility}, viewer)
       when type in [:narration, :action, :dice, :turn, :system],
       do: visibility == "all" or (viewer == "dm" and visibility == "dm")

  defp visible?(_, _), do: false

  defp text_of(p) when is_map(p) do
    String.trim(p["text"] || p[:text] || "")
  end

  # Build a one-line turn header: "[R3 · combate · Turno de Vex]" — short,
  # scannable, identical shape to the UI's turn block.
  defp turn_header(actor, %{"round" => round, "phase" => phase}) do
    phase_tag = if phase == "combat", do: " · " <> dgettext("prompts", "combate"), else: ""
    "R#{round}#{phase_tag} · " <> turn_of(actor)
  end

  defp turn_header(actor, _), do: turn_of(actor)

  defp turn_of(actor), do: dgettext("prompts", "Turno de %{actor}", actor: actor_label(actor))

  # DM narrates as the world; a PC bot narrates in their voice. The label
  # tells the model who's speaking without us having to inject role tags
  # the provider doesn't support.
  defp actor_label("dm"), do: "DM"
  defp actor_label(name), do: name

  defp narration_msg(actor, nil, text),
    do: msg_response("[#{actor_label(actor)}]: #{text}")

  defp narration_msg(actor, turn_hdr, text),
    do: msg_response("[#{turn_hdr}] [#{actor_label(actor)}]: #{text}")

  defp action_msg(actor, nil, text),
    do: msg_request("[#{declares(actor)}]: \"#{text}\"")

  defp action_msg(actor, turn_hdr, text),
    do: msg_request("[#{turn_hdr}] [#{declares(actor)}]: \"#{text}\"")

  defp declares(actor), do: dgettext("prompts", "%{actor} declara", actor: actor_label(actor))

  defp dice_msg(line), do: msg_request(line)

  defp system_msg(note), do: msg_request("[" <> dgettext("prompts", "sistema") <> "]: #{note}")

  # Both message builders sanitize UTF-8 before coalescing/compression, which
  # must preserve those character boundaries. A single stray lead
  # byte (e.g. `0xC2` without continuation) in any stored line — narration,
  # dice, or a `:system` note that itself embeds `inspect(reason)` of a previous
  # Jason.EncodeError — breaks Jason when the history is serialized into the
  # model request, wedging the partida permanently (every beat fails, resume
  # fails again because the bad byte is still in the reconstructed history).
  # Dirty legacy input is cleaned here; later shortening must not corrupt it.
  defp msg_request(text),
    do:
      Message.new_request([
        %Part.User{content: Dragonex.Text.sanitize_utf8(text), timestamp: DateTime.utc_now()}
      ])

  defp msg_response(text),
    do: Message.new_response([%Part.Text{content: Dragonex.Text.sanitize_utf8(text)}])

  # If the previous message is a Response (assistant), we don't want two in a
  # row from DIFFERENT actors confusing the provider (the model loses track of
  # who said what and starts re-narrating / re-assigning actions — the root
  # cause of the partida's "temporal loop" where the DM re-summoned a demonio
  # the PCs had already beaten). So we ONLY collapse a Response onto the previous
  # one when BOTH carry the SAME actor label (`[DM]:`, `[Lyra]:`, …). Runs from
  # the same actor (the common case: DM mid-beat declaration + DM final wrap-up,
  # or a PC's two-paragraph turn) still merge to save tokens; runs from
  # different actors stay as separate assistant turns with their own `[actor]:`
  # tag, so attribution survives.
  defp coalesce_assistant_runs(messages) do
    messages
    |> Enum.reduce([], fn
      %Response{parts: [%Part.Text{content: c1}]} = r,
      [%Response{parts: [%Part.Text{content: c2}]} | _] = acc
      when is_binary(c1) and is_binary(c2) ->
        a1 = narration_actor(c1)
        a2 = narration_actor(c2)

        if a1 != nil and a1 == a2 do
          [%Response{r | parts: [%Part.Text{content: c2 <> "\n" <> c1}]} | tl(acc)]
        else
          [r | acc]
        end

      msg, acc ->
        [msg | acc]
    end)
    |> Enum.reverse()
  end

  # Extract the actor from a narration's leading prefix. Narrations are shaped
  # either `[R3 · combate · Turno de Vex] [Vex]: <body>` (with a turn header) or
  # `[Vex]: <body>` (without). The ACTOR label is the last `[X]:` prefix whose
  # inner text has no `·` (turn headers always carry `·`; actor labels never
  # do). Returns nil when no actor label is found (defensive: callers treat nil
  # as "don't merge").
  defp narration_actor(text) do
    prefix_regex = ~r/^(?:\[[^\]\n]{1,60}\][:\s]*)+/

    case Regex.run(prefix_regex, text, return: :index) do
      [{0, len} | _] when len > 0 ->
        prefix = binary_part(text, 0, len)

        # The ACTOR label is the last `[X]` tag in the prefix that has no `·`
        # (turn headers always carry `·`; actor labels like `[DM]`/`[Vex]`
        # never do). Returns nil when no actor tag is found.
        ~r/\[([^\]]+)\]/
        |> Regex.scan(prefix, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&String.contains?(&1, "·"))
        |> List.last()

      _ ->
        nil
    end
  end

  # A structured roll entry → one scannable line:
  #   "[🎲 goblin]: ataque a Thane con scimitar d20:9 +4 = 13 vs CA 16 → fallo"
  # Matches what the chat shows, so the model reads exactly what the players saw.
  defp dice_line(actor, %{} = p) do
    dice_str =
      (p["dice"] || p[:dice] || [])
      |> Enum.map(fn
        [s, v] -> "d#{s}:#{v}"
        {s, v} -> "d#{s}:#{v}"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    reason = p["reason"] || p[:reason] || dgettext("prompts", "tirada")
    total = p["total"] || p[:total]
    against = format_against(p["against"] || p[:against])
    outcome = format_outcome(p["outcome"] || p[:outcome])

    who = p["who"] || p[:who] || actor

    parts =
      ["[🎲 #{who}]", reason, dice_str]
      |> then(fn ps ->
        if total do
          dice =
            (p["dice"] || p[:dice] || [])
            |> Enum.map(fn
              [_, v] -> v
              {_, v} -> v
              _ -> 0
            end)
            |> Enum.sum()

          mod = Dragonex.RollTotals.modifier(p, dice)

          case mod do
            m when m > 0 -> ps ++ ["+#{m}", "= #{total}"]
            m when m < 0 -> ps ++ ["#{m}", "= #{total}"]
            _ -> ps ++ ["= #{total}"]
          end
        else
          ps
        end
      end)

    parts =
      (parts ++ [Dragonex.RollTotals.minimum_note(p), against, outcome])
      |> Enum.reject(&(&1 in ["", nil]))

    Enum.join(parts, " ")
  end

  defp format_against(nil), do: ""

  defp format_against(v) do
    case v do
      ["ac", n] -> against_ac(n)
      ["dc", n] -> against_dc(n)
      {:ac, n} -> against_ac(n)
      {:dc, n} -> against_dc(n)
      _ -> ""
    end
  end

  defp against_ac(n), do: dgettext("prompts", "vs CA %{ac}", ac: n)
  defp against_dc(n), do: dgettext("prompts", "vs DC %{dc}", dc: n)

  defp format_outcome(nil), do: ""
  defp format_outcome(o) when is_atom(o), do: format_outcome(Atom.to_string(o))

  defp format_outcome(o) when is_binary(o) do
    case o do
      "hit" -> "→ " <> dgettext("prompts", "¡ACIERTO!")
      "crit" -> "→ " <> dgettext("prompts", "¡CRÍTICO!")
      x when x in ["miss", "fail"] -> "→ " <> dgettext("prompts", "fallo")
      "crit_fail" -> "→ " <> dgettext("prompts", "dos fallos de salvación de muerte")
      "success" -> "→ " <> dgettext("prompts", "éxito")
      "failure" -> "→ " <> dgettext("prompts", "fallo")
      "revive" -> "→ " <> dgettext("prompts", "¡revive!")
      _ -> ""
    end
  end
end
