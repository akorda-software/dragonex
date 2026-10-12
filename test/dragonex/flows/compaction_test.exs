defmodule Dragonex.Flows.CompactionTest do
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
        keep_recent: Dragonex.Agent.compaction_window(4),
        summarize: fn old ->
          "Earlier, the party explored #{length(old)} rooms."
        end
      ]
    }

    owner = self()

    model = %ExAgent.Models.Test{
      script: [
        fn request, _ ->
          send(owner, {:projection, request})
          "next room"
        end
      ]
    }

    agent =
      ExAgent.new(
        model: model,
        capabilities: [compaction]
      )

    assert {:ok, %{messages: messages}} =
             ExAgent.run(agent, "turn 25: the throne room", message_history: history)

    assert_receive {:projection, projection}
    assert length(projection) < 12

    # The summary is the first message, and the recent window (incl. the current
    # prompt) survived verbatim. (exAgent 1.0 compacts only the PRIOR history,
    # keeping `keep_recent` of the 24 turns verbatim, so 24 - 4 = 20 are summed.)
    summary =
      projection
      |> Enum.flat_map(& &1.parts)
      |> Enum.find(fn
        %Part.User{content: content} -> content =~ "20 rooms"
        %Part.System{content: content} -> content =~ "20 rooms"
        _ -> false
      end)

    assert summary
    summary = summary.content
    assert summary =~ "20 rooms"

    if Dragonex.Models.backend() == :req_llm do
      assert length(messages) == 26
      assert Enum.take(messages, 24) == history
    else
      assert length(messages) < 12
    end

    assert Enum.any?(projection, fn
             %Request{parts: parts} ->
               Enum.any?(parts, &match?(%Part.User{content: "turn 25: the throne room"}, &1))

             _ ->
               false
           end)
  end
end
