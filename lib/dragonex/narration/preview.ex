defmodule Dragonex.Narration.Preview do
  @moduledoc """
  Live preview of structured narration while the model is still generating it
  (R16). The public text travels as the `text` argument of `narrate` or
  `final_result`; exAgent forwards the raw argument JSON fragments
  (`on_tool_call_delta`). This module accumulates them per tool call and reads
  the `text` value generated so far, so the table can show it as it is written.

  A preview is never a publication: the validated `final_result` and
  `narrate` events stay the only durable narration, and the table replaces the
  bubble with them. Other tools, and the human resolver's voice, never preview.
  """

  @previewed ~w(narrate final_result)

  @type t :: %{
          optional(non_neg_integer()) => %{
            name: String.t() | nil,
            buffer: binary(),
            sent: non_neg_integer()
          }
        }

  def new, do: %{}

  @doc """
  The beat's `on_tool_call_delta`: previews this actor's narration on the
  table as `{:text_delta, game_id, turn_id, actor, chunk}`, the message the
  table's live bubble already renders (and scrubs). A human resolver's voice
  comes from the literal declaration, so it never previews; nil disables it.
  """
  def broadcaster(%{human_declaration: text}) when is_binary(text) and text != "", do: nil

  def broadcaster(%{game_id: game_id, turn_id: turn_id, actor: actor}) do
    # exAgent invokes the callback from the single process driving the run.
    key = {__MODULE__, turn_id}

    fn delta ->
      {acc, fresh} = push(Process.get(key, new()), delta)
      Process.put(key, acc)

      if fresh != "" do
        Phoenix.PubSub.broadcast(
          Dragonex.PubSub,
          "dragonex:game:#{game_id}",
          {:text_delta, game_id, turn_id, actor, fresh}
        )
      end

      :ok
    end
  end

  def broadcaster(_beat), do: nil

  @doc "Add one fragment; return the accumulator and the newly readable text."
  def push(acc, %{index: index, fragment: fragment} = delta) do
    call =
      case delta do
        # A named delta opens a new call at this index.
        %{name: name} when is_binary(name) -> %{name: name, buffer: "", sent: 0}
        _ -> Map.get(acc, index, %{name: nil, buffer: "", sent: 0})
      end

    call = %{call | buffer: call.buffer <> fragment}

    if call.name in @previewed do
      text = text_so_far(call.buffer)
      size = String.length(text)
      fresh = if size > call.sent, do: String.slice(text, call.sent, size - call.sent), else: ""
      {Map.put(acc, index, %{call | sent: max(size, call.sent)}), fresh}
    else
      {Map.put(acc, index, call), ""}
    end
  end

  @doc """
  The `text` string value as far as it has been generated, decoded. Works on
  an incomplete JSON object, with or without exAgent's `arguments` envelope.
  """
  def text_so_far(buffer) when is_binary(buffer) do
    case Regex.run(~r/"text"\s*:\s*"/u, buffer, return: :index) do
      [{start, length}] ->
        buffer
        |> binary_part(start + length, byte_size(buffer) - start - length)
        |> decode([])

      _ ->
        ""
    end
  end

  # Decode a JSON string body until its closing quote or the end of input.
  # An escape cut at the end is left for the next fragment.
  defp decode(<<?", _::binary>>, out), do: finish(out)

  defp decode(<<?\\, ?u, hex::binary-size(4), rest::binary>>, out) do
    case Integer.parse(hex, 16) do
      {code, ""} -> decode(rest, [<<code::utf8>> | out])
      _ -> finish(out)
    end
  end

  defp decode(<<?\\, ?u, _::binary>>, out), do: finish(out)
  defp decode(<<?\\, c, rest::binary>>, out), do: decode(rest, [escape(c) | out])
  defp decode(<<?\\>>, out), do: finish(out)
  defp decode(<<c::utf8, rest::binary>>, out), do: decode(rest, [<<c::utf8>> | out])
  # A multibyte character cut mid-way waits for its remaining bytes.
  defp decode(_partial, out), do: finish(out)

  defp finish(out), do: out |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape(?n), do: "\n"
  defp escape(?t), do: "\t"
  defp escape(?r), do: ""
  defp escape(?b), do: ""
  defp escape(?f), do: ""
  defp escape(c), do: <<c>>
end
