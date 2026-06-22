defmodule Dragones.Flows.CompactionTest do
  @moduledoc """
  Flow 8 — a long campaign compacts.

  A long session (many narration turns) would blow the context window. The
  Compaction capability shrinks the history to a summary + recent window before
  each model request, keeping the DM's recent turns verbatim. Validates the
  real game need: a campaign that runs for hours doesn't price itself out.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Compaction
  alias ExAgent.Message.{Part, Request}

  @tag :compaction
  test "a long narration history compacts to summary + recent window" do
    # A realistic long history: 24 narration turns.
    history =
      for i <- 1..24 do
        %Request{
          parts: [%Part.User{content: "turn #{i}: the party explores room #{i}, finds lore #{i}"}],
          timestamp: DateTime.utc_now()
        }
      end

    compaction = %Compaction.Capability{
      compactor: Compaction.Summary,
      opts: [
        threshold_tokens: 50,
        keep_recent: 4,
        summarize: fn old ->
          "Earlier, the party explored #{length(old)} rooms."
        end
      ]
    }

    agent =
      ExAgent.new(
        model: %ExAgent.Models.Test{label: "next room"},
        capabilities: [compaction]
      )

    assert {:ok, %{messages: messages}} =
             ExAgent.run(agent, "turn 25: the throne room", message_history: history)

    # Compacted: far fewer than the 24 history + this turn.
    assert length(messages) < 12

    # The summary is the first message, and the recent window (incl. the current
    # prompt) survived verbatim. (exAgent 1.0 compacts only the PRIOR history,
    # keeping `keep_recent` of the 24 turns verbatim, so 24 - 4 = 20 are summed.)
    [%Request{parts: [%Part.System{content: summary} | _]} | _] = messages
    assert summary =~ "20 rooms"

    assert Enum.any?(messages, fn
             %Request{parts: parts} ->
               Enum.any?(parts, &match?(%Part.User{content: "turn 25: the throne room"}, &1))

             _ ->
               false
           end)
  end
end
