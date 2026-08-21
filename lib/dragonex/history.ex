defmodule Dragonex.History do
  @moduledoc """
  Reconstructs a shared conversation history from the partida's append-only
  `game_events` timeline, so every agent (DM + each AI PC) sees the SAME
  context: every prior narration, every declared action, every die roll —
  not just its own turns.

  ## Why this exists

  ExAgent's `Server` keeps an internal `state.history` per agent, but that
  history only contains what THAT agent said. Without a shared reconstruction,
  the DM never reads what the bot Vex declared verbatim, the bot Lyra never
  sees the DM's narration for Thane's turn, and cross-agent coherence
  collapses (Vex attacks maniquíes while Lyra "discovers" a library — each
  in their own bubble).

  `from_events/1` flattens the timeline into a `[Message.t()]` list that we
  pass as `:message_history` to every `Server.chat/3` call. Each agent then
  prepends its OWN system prompt + story bible (its particular voice) on top
  of the common history, getting full situational awareness plus its role.

  ## Layout per event

    * `:turn` (kind: :start) — doesn't get its own message. It's folded as a
      header line into the NEXT narration/action so the model always knows
      "what turn / whose turn / what phase" each snippet belongs to.
    * `:narration` (mid-beat or final, by DM or any AI PC) — one assistant
      `Response` per contiguous run of narration lines by the SAME actor,
      prefixed `[<actor>]:` so the model can attribute voice.
    * `:action` (the HUMAN's chat-input declaration) — one user `Request`,
      prefixed `[<actor> declara]:` so the model treats it as the player's
      intent, not narration.
    * `:dice` — embebed inline in the surrounding narration when possible;
      standalone dice (rare) become a one-line `Request` labeled `[🎲 ...]`
      so the model still sees the result.
    * `:system` (combat ended, partida created, etc.) — a short user `Request`
      labeled `[sistema]:` so the model treats it as scene framing.

  Tool-call history (the actual `make_attack` invocations) is NOT reconstructed:
  the resolved result is what matters narratively, and it's already captured
  in the `:dice` line that follows. Replaying raw tool calls would balloon
  tokens without adding info the prose doesn't already carry.
  """

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

  @type event :: GameEvent.t()

  @spec from_events([event()]) :: [Message.t()]
  def from_events(events) when is_list(events) do
    events
    |> Enum.filter(&visible?/1)
    |> Enum.reduce({nil, []}, &reduce_event/2)
    |> elem(1)
    |> coalesce_assistant_runs()
    |> compress_old_narrations(@recent_narrations_kept)
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

  # Keep up to ~180 chars, ending at the first ".¡!?" after 80 chars (so we
  # don't break the leading attribution tag). Append "…" when truncated.
  defp first_sentence(text) do
    if String.length(text) <= 180 do
      text
    else
      # Find a sentence terminator after the attribution header.
      case Regex.run(~r/^(.{80,180}?[.!?¡])/, text, capture: :all) do
        [match | _] -> String.trim_trailing(match) <> " …"
        nil -> String.slice(text, 0, 180) <> "…"
      end
    end
  end

  defp reduce_event(e, {pending_turn, acc}) do
    case e do
      # Stash the turn header; it'll prefix the next narration/action.
      %{type: :turn, payload: %{"kind" => "start"} = p} ->
        {turn_header(e.actor, p), acc}

      %{type: :turn} ->
        # Other :turn kinds (none today, defensive).
        {pending_turn, acc}

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
  # resolution events (their outcome is in the `:dice` line) and anything
  # dm-only (the timeline already carries visibility, but the events list we
  # get from Games.list_events/1 includes dm-only system notes — drop them).
  defp visible?(%{type: t}) when t in [:narration, :action, :dice, :turn, :system], do: true
  defp visible?(_), do: false

  defp text_of(p) when is_map(p) do
    String.trim(p["text"] || p[:text] || "")
  end

  # Build a one-line turn header: "[R3 · combate · Turno de Vex]" — short,
  # scannable, identical shape to the UI's turn block.
  defp turn_header(actor, %{"round" => round, "phase" => phase}) do
    phase_tag = if phase == "combat", do: " · combate", else: ""
    "R#{round}#{phase_tag} · Turno de #{actor_label(actor)}"
  end

  defp turn_header(actor, _), do: "Turno de #{actor_label(actor)}"

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
    do: msg_request("[#{actor_label(actor)} declara]: \"#{text}\"")

  defp action_msg(actor, turn_hdr, text),
    do: msg_request("[#{turn_hdr}] [#{actor_label(actor)} declara]: \"#{text}\"")

  defp dice_msg(line), do: msg_request(line)

  defp system_msg(note), do: msg_request("[sistema]: #{note}")

  # Both message builders sanitize UTF-8 as the last step. A single stray lead
  # byte (e.g. `0xC2` without continuation) in any stored line — narration,
  # dice, or a `:system` note that itself embeds `inspect(reason)` of a previous
  # Jason.EncodeError — breaks Jason when the history is serialized into the
  # model request, wedging the partida permanently (every beat fails, resume
  # fails again because the bad byte is still in the reconstructed history).
  # This is the single chokepoint that guarantees the history is always clean.
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

    reason = p["reason"] || p[:reason] || "tirada"
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

          mod = total - dice

          case mod do
            m when m > 0 -> ps ++ ["+#{m}", "= #{total}"]
            m when m < 0 -> ps ++ ["#{m}", "= #{total}"]
            _ -> ps ++ ["= #{total}"]
          end
        else
          ps
        end
      end)

    parts = (parts ++ [against, outcome]) |> Enum.reject(&(&1 in ["", nil]))
    Enum.join(parts, " ")
  end

  defp format_against(nil), do: ""

  defp format_against(v) do
    case v do
      ["ac", n] -> "vs CA #{n}"
      ["dc", n] -> "vs DC #{n}"
      {:ac, n} -> "vs CA #{n}"
      {:dc, n} -> "vs DC #{n}"
      _ -> ""
    end
  end

  defp format_outcome(nil), do: ""
  defp format_outcome(o) when is_atom(o), do: format_outcome(Atom.to_string(o))

  defp format_outcome(o) when is_binary(o) do
    case o do
      x when x in ["hit", "crit"] -> "→ ¡ACIERTO!"
      x when x in ["miss", "crit_fail"] -> "→ fallo"
      "success" -> "→ éxito"
      "failure" -> "→ fallo"
      "revive" -> "→ ¡revive!"
      _ -> ""
    end
  end
end
