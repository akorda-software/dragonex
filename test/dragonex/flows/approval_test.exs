defmodule Dragonex.Flows.ApprovalTest do
  @moduledoc """
  Flow 9 — destructive actions need human approval.

  Some game actions are costly enough that a human should confirm: a long rest
  (advances time, resets resources), leveling up, permanently spending gold.
  ExAgent.Permissions with a `:ask` rule + an `:approve` callback models this:
  the tool is gated, the approve fn (a LiveView confirmation dialog in the real
  app) decides whether it runs.
  """

  use ExUnit.Case, async: true

  alias ExAgent.{Message, Permissions}
  alias ExAgent.Message.Part

  defp game_tools do
    [
      ExAgent.Tool.new(
        name: "long_rest",
        description: "Take a long rest (resets HP and slots, advances a day).",
        parameters_json_schema: %{type: "object", properties: %{}},
        takes_ctx: false,
        call: fn _ -> {:ok, "the party rests; a new day dawns"} end
      ),
      ExAgent.Tool.new(
        name: "look",
        description: "Look around (free, no approval).",
        parameters_json_schema: %{type: "object", properties: %{}},
        takes_ctx: false,
        call: fn _ -> {:ok, "you see the tavern"} end
      )
    ]
  end

  # Destructive tools need :ask; benign ones are :allow.
  defp perms do
    Permissions.new!(rules: [{"*", :allow}, {"long_rest", :ask}, {"level_up", :ask}])
  end

  defp find_return(messages, name) do
    Enum.find_value(messages, fn
      %Message.Request{parts: parts} ->
        Enum.find(parts, &match?(%Part.ToolReturn{tool_name: ^name}, &1))

      _ ->
        nil
    end)
  end

  test "a destructive tool runs when the human approves" do
    model = %ExAgent.Models.Test{
      script: [
        {:tool_calls, [%Part.ToolCall{tool_name: "long_rest", args: %{}}]},
        "done"
      ]
    }

    agent = ExAgent.new(model: model, tools: game_tools())

    assert {:ok, %{messages: messages}} =
             ExAgent.run(agent, "we rest",
               permissions: perms(),
               approve: fn %Part.ToolCall{tool_name: "long_rest"} -> :approve end
             )

    assert find_return(messages, "long_rest").content =~ "new day dawns"
  end

  test "the same tool is blocked when the human denies" do
    model = %ExAgent.Models.Test{
      script: [
        {:tool_calls, [%Part.ToolCall{tool_name: "long_rest", args: %{}}]},
        "ok, no rest"
      ]
    }

    agent = ExAgent.new(model: model, tools: game_tools())

    assert {:ok, %{messages: messages}} =
             ExAgent.run(agent, "we rest",
               permissions: perms(),
               approve: fn _ -> :deny end
             )

    assert find_return(messages, "long_rest").content =~ "not permitted"
  end

  test "a benign tool runs without the approve callback being consulted" do
    model = %ExAgent.Models.Test{
      script: [
        {:tool_calls, [%Part.ToolCall{tool_name: "look", args: %{}}]},
        "ok"
      ]
    }

    agent = ExAgent.new(model: model, tools: game_tools())

    # No approve needed for an :allow tool.
    assert {:ok, %{messages: messages}} =
             ExAgent.run(agent, "look around", permissions: perms())

    assert find_return(messages, "look").content =~ "tavern"
  end
end
