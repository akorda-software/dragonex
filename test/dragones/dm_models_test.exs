defmodule Dragones.DMModelsTest do
  use ExUnit.Case, async: true

  alias Dragones.{DM, Models}
  alias ExAgent.{Compaction, Message, Server}

  describe "system_prompt/1" do
    test "includes the campaign bible in the stable prefix" do
      prompt = DM.system_prompt(%{"hook" => "the lost relic", "tone" => "gritty"})

      assert prompt =~ "BIBLIA DE LA CAMPAÑA"
      assert prompt =~ "the lost relic"
      assert prompt =~ "gritty"
    end

    test "omits the bible section when empty" do
      refute DM.system_prompt(%{}) =~ "BIBLIA DE LA CAMPAÑA"
    end
  end

  describe "DM.new/2 compaction wiring" do
    test "wires a Compaction.Summary capability when a summarizer is given" do
      agent = DM.new(%ExAgent.Models.Test{label: "x"}, summarizer: %ExAgent.Models.Test{label: "s"})

      assert Enum.any?(agent.capabilities, &match?(%Compaction.Capability{}, &1))
    end

    test "wires no compaction when no summarizer is given" do
      agent = DM.new(%ExAgent.Models.Test{label: "x"})

      refute Enum.any?(agent.capabilities, &match?(%Compaction.Capability{}, &1))
    end
  end

  describe "compaction firing through the Server" do
    # A long conversation (many short beats) crosses a low threshold; the old
    # messages are replaced by the summarize fn's output, keeping only the recent
    # window verbatim. Uses a deterministic summarize fn (no LLM).
    test "old history is replaced by a summary once the threshold is crossed" do
      compaction = %Compaction.Capability{
        compactor: Compaction.Summary,
        opts: [
          threshold_tokens: 5,
          keep_recent: 2,
          summarize: fn _old -> "RECAP: the goblin attacked twice and missed." end
        ]
      }

      agent =
        ExAgent.new(
          model: %ExAgent.Models.Test{label: "ok."},
          instructions: "Be brief.",
          capabilities: [compaction]
        )

      {:ok, server} = Server.start_link(agent: agent, agent_id: "compact-#{System.unique_integer([:positive])}")

      # Several short chats build up history well past the 20-token threshold.
      for n <- 1..6, do: assert({:ok, _} = Server.chat(server, "turn #{n}"))

      history = Server.history(server)

      # The summary landed in the history...
      texts = history |> Message.parts() |> Enum.map_join("\n", &part_text/1)
      assert texts =~ "RECAP: the goblin attacked twice"
      # ...and the history is bounded (no longer carries every old turn).
      refute texts =~ "turn 1"
      assert texts =~ "turn 6"
    end
  end

  describe "Models.cached_tokens/1" do
    # parse_usage flattens prompt_tokens_details.cached_tokens into a scalar
    # details["cached_tokens"]; that's the shape a Usage carries after a run.
    test "reads cached_tokens from the flattened details" do
      assert Models.cached_tokens(%{details: %{"cached_tokens" => 1200}}) == 1200
    end

    test "handles missing/unknown shapes" do
      assert Models.cached_tokens(%{details: %{}}) == 0
      assert Models.cached_tokens(%{details: %{"cached_tokens" => nil}}) == 0
      assert Models.cached_tokens(nil) == 0
    end
  end

  defp part_text(%Message.Part.Text{content: c}), do: c
  defp part_text(%Message.Part.User{content: c}) when is_binary(c), do: c
  defp part_text(%Message.Part.System{content: c}) when is_binary(c), do: c
  defp part_text(_), do: ""
end
