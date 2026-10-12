defmodule Dragonex.SpeechEcho do
  @moduledoc """
  Detects repeated public speech inside one actor's turn, so views can show it
  once without deleting or rewriting the durable events (D227).

  Two sources produce echoes:

    * A manual turn publishes the human `:action` and, after its tools, the
      same literal words as a `:narration` tagged `human_declaration` (D221).
      The action is then "voiced": a view can show it in its own position and
      drop the later copy.
    * A structured run publishes intermediate speech (`narrate`) and then a
      `final_result` that copies it, contains it, is contained by it or barely
      rewords it. Only these shapes are folded; a paraphrase or a continuation
      that adds new outcomes keeps both lines.

  The rules apply only within the same actor and non-nil `turn_id`; distinct
  completed narrations are kept unless they are exact copies. When one text
  contains the other the longer stays; otherwise the later stays, because it
  was written after the tool results.

  Pure and deterministic: no DB, World or model access.
  """

  @near_duplicate 0.6
  @min_contained_words 4

  @type result :: %{hidden: MapSet.t(integer()), voiced: MapSet.t(integer())}

  @doc "Seqs to hide and the seqs of `:action` events whose voice was published."
  @spec analyze([map()]) :: result()
  def analyze(events) when is_list(events) do
    init = %{hidden: MapSet.new(), voiced: MapSet.new(), actions: %{}, last: %{}}

    events
    |> Enum.reduce(init, &step/2)
    |> Map.take([:hidden, :voiced])
  end

  defp step(%{type: :action, seq: seq, actor: actor, payload: p}, acc) do
    case key(actor, p) do
      nil ->
        acc

      key ->
        update_in(
          acc.actions,
          &Map.update(&1, key, [{seq, norm(p)}], fn l -> [{seq, norm(p)} | l] end)
        )
    end
  end

  defp step(%{type: :narration, seq: seq, actor: actor, payload: p}, acc) do
    case key(actor, p) do
      nil ->
        acc

      key ->
        if field(p, "kind") in ["human_declaration", :human_declaration],
          do: human_voice(acc, key, seq, norm(p)),
          else: speech(acc, key, seq, p)
    end
  end

  defp step(_event, acc), do: acc

  defp human_voice(acc, _key, _seq, ""), do: acc

  defp human_voice(acc, key, seq, text) do
    case Enum.find(Map.get(acc.actions, key, []), fn {_seq, action} -> action == text end) do
      {action_seq, _} ->
        %{acc | hidden: MapSet.put(acc.hidden, seq), voiced: MapSet.put(acc.voiced, action_seq)}

      nil ->
        acc
    end
  end

  defp speech(acc, key, seq, payload) do
    cur = %{seq: seq, text: norm(payload), complete: field(payload, "complete") == true}

    cond do
      cur.text == "" ->
        acc

      prev = Map.get(acc.last, key) ->
        case echo(prev, cur) do
          :hide_prev -> hide(acc, prev.seq) |> remember(key, cur)
          :hide_cur -> hide(acc, cur.seq) |> remember(key, %{prev | complete: cur.complete})
          :distinct -> remember(acc, key, cur)
        end

      true ->
        remember(acc, key, cur)
    end
  end

  defp echo(%{text: same}, %{text: same}), do: :hide_prev
  defp echo(%{complete: true}, _cur), do: :distinct

  defp echo(prev, cur) do
    cond do
      contains?(cur.text, prev.text) -> :hide_prev
      contains?(prev.text, cur.text) -> :hide_cur
      similarity(prev.text, cur.text) >= @near_duplicate -> :hide_prev
      true -> :distinct
    end
  end

  defp hide(acc, seq), do: %{acc | hidden: MapSet.put(acc.hidden, seq)}
  defp remember(acc, key, cur), do: %{acc | last: Map.put(acc.last, key, cur)}

  defp key(actor, p) do
    case field(p, "turn_id") do
      id when is_binary(id) and id != "" and is_binary(actor) -> {actor, id}
      _ -> nil
    end
  end

  # Word-bounded containment of a text with enough words to be a real echo.
  defp contains?(long, short) do
    length(String.split(short)) >= @min_contained_words and
      String.contains?(" " <> long <> " ", " " <> short <> " ")
  end

  # Jaccard over 5-letter stems of the words with 4+ letters. Real near-copies
  # score 0.73–0.88; paraphrases and continuations stay at or below 0.33.
  defp similarity(a, b) do
    {wa, wb} = {stems(a), stems(b)}
    union = MapSet.size(MapSet.union(wa, wb))
    if union == 0, do: 0.0, else: MapSet.size(MapSet.intersection(wa, wb)) / union
  end

  defp stems(text) do
    for w <- String.split(text),
        String.length(w) >= 4,
        into: MapSet.new(),
        do: String.slice(w, 0, 5)
  end

  defp norm(payload) do
    case field(payload, "text") do
      text when is_binary(text) ->
        text
        |> String.downcase()
        |> :unicode.characters_to_nfd_binary()
        |> String.replace(~r/\p{Mn}/u, "")
        |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
        |> String.split()
        |> Enum.join(" ")

      _ ->
        ""
    end
  end

  # Persisted payloads have string keys; a payload built in-process has atoms.
  @atom_keys %{"text" => :text, "turn_id" => :turn_id, "kind" => :kind, "complete" => :complete}

  defp field(p, key) when is_map(p), do: Map.get(p, key, Map.get(p, Map.fetch!(@atom_keys, key)))
  defp field(_, _), do: nil
end
