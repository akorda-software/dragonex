defmodule DragonexWeb.GameLive.Chat do
  @moduledoc """
  Chat timeline view-model for the game table — pure functions from snapshot
  events to the turn-blocks the LiveView renders.

  Extracted from `DragonexWeb.GameLive.Show` so the grouping/labeling rules
  (who speaks, DM vs PC roles, live streaming bubble) live apart from the
  LiveView's event handling.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{SpeechEcho, Text}
  alias DragonexWeb.GameLive.RollFormat

  # A session cursor can still point at the DM during scene review/handoff.
  # These stages have no narrator, so they also flush the finished preview.
  def busy_actor(%{busy_stage: stage}) when stage in [:scene_review, :turnmaster, :retrying],
    do: nil

  def busy_actor(%{status: :running, current: current}), do: current
  def busy_actor(_), do: nil

  def busy_label(:scene_review, _actor), do: dgettext("ui", "Actualizando la escena…")
  def busy_label(:turnmaster, _actor), do: dgettext("ui", "Organizando el siguiente turno…")
  def busy_label(:retrying, _actor), do: dgettext("ui", "Reintentando el turno…")
  def busy_label(_stage, "dm"), do: dgettext("ui", "el DM está narrando…")
  def busy_label(_stage, nil), do: dgettext("ui", "el DM está pensando…")
  def busy_label(_stage, actor), do: dgettext("ui", "%{actor} está actuando…", actor: actor)

  # Streaming bubble state machine, re-evaluated on every `:game_updated`
  # re-render. The bubble shows the text currently being generated; it must
  # flush (clear) the moment a streamed segment has been persisted as a chat
  # card, so the NEXT segment (the model's reaction after a mid-beat tool call)
  # streams fresh instead of appending to the already-carded text.
  #
  # We detect "a new segment just landed" by comparing the seq of the actor's
  # latest narration against the seq we saw when the bubble started filling.
  # This is robust where a text comparison would not be: the persisted text is
  # scrubbed (`Text.scrub/2` strips leading tags, the actor's own name, HP
  # leaks…) while the bubble holds the RAW stream, so they routinely differ.
  #
  # On a beat/actor change we clear the bubble AND seed `last_seq` to the new
  # actor's latest narration, so the segment that's ALREADY on screen when we
  # connect doesn't count as "new" and flush prematurely.
  def compute_live_state(busy, events, live_actor, live_text, live_turn_id, prev_seq) do
    live_text = live_text || ""
    prev_seq = prev_seq || 0
    latest_seq = last_narration_seq(events, busy) || 0

    cond do
      busy == nil or busy != live_actor ->
        %{text: "", last_seq: latest_seq, turn_id: nil, actor: nil}

      live_text != "" and latest_seq > prev_seq ->
        %{text: "", last_seq: latest_seq, turn_id: live_turn_id, actor: live_actor}

      true ->
        %{text: live_text, last_seq: prev_seq, turn_id: live_turn_id, actor: live_actor}
    end
  end

  defp last_narration_seq(events, actor) do
    events
    |> Enum.reverse()
    |> Enum.find(fn e -> e.type == :narration and e.actor == actor end)
    |> case do
      nil -> nil
      e -> e.seq
    end
  end

  # CSS class for the turn header actor label: highlights the viewer's own turn
  # and tones down the DM's.
  def th_actor_class(actor, viewer, auto_play) do
    cond do
      actor == viewer and auto_play -> "auto"
      actor == viewer -> "mine"
      actor == "dm" -> "dm-side"
      true -> ""
    end
  end

  # The header label for the acting character: "TÚ" if the viewer is manually
  # controlling them; "🤖 <name> (auto)" if they enabled auto-play on their own
  # character; otherwise just the name (or "Turno del DM").
  def turn_header_label("dm", _viewer, _auto), do: dgettext("ui", "Turno del DM")

  def turn_header_label(actor, viewer, true) when actor == viewer do
    dgettext("ui", "🤖 %{actor} (auto)", actor: actor)
  end

  def turn_header_label(actor, viewer, _auto) when actor == viewer do
    dgettext("ui", "%{actor} · TÚ", actor: actor)
  end

  def turn_header_label(actor, _viewer, _auto),
    do: dgettext("ui", "Turno de %{actor}", actor: actor)

  @doc "Header label for a timeline block; a DM combat turn names its combatant."
  def header_label(%{actor: "dm", combatant: name}, _viewer, _auto) when is_binary(name),
    do: dgettext("ui", "Turno de %{actor}", actor: name)

  def header_label(%{actor: actor}, viewer, auto), do: turn_header_label(actor, viewer, auto)

  def live_shown(text, actor, pc_names \\ [], character_names \\ []),
    do: Text.scrub(text || "", actor, pc_names: pc_names, character_names: character_names)

  def show_live_who?(text, actor)
      when is_binary(actor) and actor != "dm" and actor != "",
      do: not leading_self?(live_shown(text, actor), actor)

  def show_live_who?(_, _), do: false

  # Group the timeline into per-turn blocks so the chat reads as a sequence of
  # turns (each with its header — who/round/phase — and its events inline),
  # instead of a flat list where narration, dice and actions pile up without
  # hierarchy. Events without a turn_id (the opening narration, legacy events,
  # system notes) land in a prologue block with no header.
  #
  # Repeated speech inside one actor turn is shown once (D227): a human action
  # whose literal voice was published later stays visible in its own position,
  # and intermediate/final copies collapse. The events themselves are kept.
  def blocks(events, viewer) do
    visible =
      Enum.filter(events, fn e ->
        if viewer == "dm", do: e.visible_to in ["all", "dm"], else: e.visible_to == "all"
      end)

    %{hidden: hidden, voiced: voiced} = SpeechEcho.analyze(visible)
    latest = List.last(visible)

    # «El turno pasa a X» repeats the next block's header; only the latest
    # handoff, still waiting for its turn to open, says something new.
    visible =
      Enum.reject(visible, &(MapSet.member?(hidden, &1.seq) or (handoff?(&1) and &1 != latest)))

    # Walk the visible events in order, opening a new block every time a
    # :turn marker appears. The marker carries turn_id/round/phase/actor.
    # Blocks are prepended (and lines prepended within each block) for O(1)
    # updates, then reversed at the end so the result is chronological — the
    # earlier `acc ++ [block]` form was O(n²) over a long timeline.
    blocks_rev =
      Enum.reduce(visible, [], fn e, acc ->
        cur = List.first(acc)

        case e do
          %{type: :turn, payload: %{"kind" => "start"} = p} ->
            header = %{
              turn_id: p["turn_id"],
              actor: e.actor,
              round: p["round"],
              phase: p["phase"],
              combatant: p["combatant"]
            }

            block = %{header: header, events: []}
            [block | acc]

          _ ->
            line = %{
              seq: e.seq,
              type: e.type,
              actor: e.actor,
              role: chat_role(e),
              who: chat_who(e),
              text: chat_text(e),
              outcome: chat_outcome(e),
              kind: if(e.type == :system, do: (e.payload || %{})["kind"]),
              declaration:
                e.type == :action and e.actor != "dm" and not MapSet.member?(voiced, e.seq)
            }

            case cur do
              nil ->
                # No open block — prologue (e.g. the opening narration).
                [%{header: nil, events: [line]} | acc]

              %{events: evs} = block ->
                [%{block | events: [line | evs]} | tl(acc)]
            end
        end
      end)

    blocks_rev
    |> Enum.reverse()
    |> Enum.map(&%{&1 | events: Enum.reverse(&1.events)})
    |> Enum.map(&infer_combatant/1)
  end

  # Turn markers before the `combatant` field: a DM combat turn whose rolls
  # all belong to one creature is that creature's turn.
  defp infer_combatant(
         %{header: %{actor: "dm", phase: "combat", combatant: nil} = header, events: events} =
           block
       ) do
    case events |> Enum.filter(&(&1.type == :dice)) |> Enum.map(& &1.who) |> Enum.uniq() do
      [name] when is_binary(name) and name != "" -> %{block | header: %{header | combatant: name}}
      _ -> block
    end
  end

  defp infer_combatant(block), do: block

  defp handoff?(%{type: :system, actor: "turnmaster", payload: %{"kind" => kind}}),
    do: kind in ["give_turn_to", "pass_to_dm"]

  defp handoff?(_), do: false

  # The role drives the CSS class. Narration by the DM → :dm. Narration/action
  # by a non-dm actor → :pc (the bot or human PC speaking in their own voice).
  # Dice → :roll. System → :system.
  defp chat_role(%{type: :narration, actor: actor}), do: if(actor == "dm", do: :dm, else: :pc)
  defp chat_role(%{type: :dice}), do: :roll
  defp chat_role(%{type: :action, actor: actor}), do: if(actor == "dm", do: :dm, else: :pc)
  defp chat_role(%{type: :turn}), do: :turn
  defp chat_role(_), do: :system

  # The label shown in the chat for each line: the acting hero's name for player
  # actions/declarations and for a PC bot's narration. DM narration carries no
  # label — it is understood to be the DM.
  # The die icon is drawn by CSS (`.msg-roll::before`), so the label is just
  # the roller's name.
  defp chat_who(%{type: :dice, actor: actor, payload: p}), do: p["who"] || actor || ""

  defp chat_who(%{type: :action, actor: actor}) when actor != "dm", do: "#{actor} ·"
  defp chat_who(%{type: :narration, actor: actor}) when actor != "dm", do: "#{actor} ·"
  defp chat_who(_), do: ""

  # True when the streaming bubble's text already opens with the actor's own
  # name (a PC bot narrating in third person, "Lyra levanta..."). In that case
  # the leading `who` span is redundant — showing it would render "LyraLyra
  # levanta...". Persisted cards are already scrubbed of this by
  # `Text.scrub/2`, but the live bubble streams RAW text, so we guard here too.
  # Word-boundary safe: the name must be followed by a separator, so
  # "Lyranthropo" never matches.
  defp leading_self?(text, actor) when is_binary(text) and is_binary(actor) and actor != "" do
    trimmed = text |> String.trim() |> String.trim_leading("—*\"'- ")
    size = byte_size(actor)

    case trimmed do
      <<prefix::binary-size(^size), rest::binary>> when prefix == actor ->
        # The card already labels the actor, so a leading self-name would render
        # doubled. The streaming bubble uses RAW (un-scrubbed) text, so we must
        # detect the self-name here too. After the name, strip any closing
        # markdown bold (`**Thane**...` → `**...`) the model emits, then accept
        # a separator OR a lowercase letter (DeepSeek sometimes glues the name
        # to the next word with no space: "Thanedeja ...").
        rest = String.trim_leading(rest, "*")
        rest == "" or Regex.match?(~r/^([:：,.\s\-—]|[a-zá-úñ])/, rest)

      _ ->
        false
    end
  end

  defp leading_self?(_, _), do: false

  defp chat_outcome(%{type: :dice, payload: p}), do: p["outcome"]
  defp chat_outcome(_), do: nil

  defp chat_text(%{type: :system, payload: p}), do: p["note"] || p[:note] || ""
  defp chat_text(%{type: :dice, payload: p}), do: RollFormat.format_line(p)
  defp chat_text(%{payload: p}), do: p["text"] || p[:text] || ""
end
