defmodule Dragonex.Flows.DelegationTest do
  @moduledoc """
  Flow 5 — rules delegation.

  The DM doesn't know every rule offhand, so it delegates a rules question to a
  cheap specialist "rules lawyer" agent via `ExAgent.Coordination.delegation_tool/2`.
  Validates pydanticAI level-2 coordination: the specialist's output flows back
  as the tool return, and its token usage is counted together with the parent's.
  """

  use ExUnit.Case, async: true

  alias ExAgent.Coordination
  alias ExAgent.Message
  alias ExAgent.Message.{Part, Usage}

  test "the DM delegates a rule lookup; the specialist answers; usage merges" do
    # The specialist knows the grappling rules.
    specialist =
      ExAgent.new(
        model: %ExAgent.Models.Test{
          script: [
            Message.new_response([%Part.Text{content: "DC = opponent's STR or DEX (higher) + 5"}],
              usage: %Usage{input_tokens: 8, output_tokens: 4},
              model_name: "test"
            )
          ]
        },
        instructions: "You are the rules lawyer."
      )

    # The DM delegates then narrates.
    parent =
      ExAgent.new(
        model: %ExAgent.Models.Test{
          script: [
            {:tool_calls,
             [
               %Part.ToolCall{
                 tool_name: "ask_rules",
                 args: %{"prompt" => "how does grappling work?"}
               }
             ]},
            "The goblin tries to grapple you!"
          ]
        },
        tools: [Coordination.delegation_tool(specialist, name: "ask_rules")]
      )

    assert {:ok, %{output: narration, usage: usage, messages: messages}} =
             ExAgent.run(parent, "The goblin grapples the fighter.")

    assert narration =~ "grapple"

    # The delegated answer flowed back as the tool return.
    assert %Part.ToolReturn{content: ret} = find_return(messages, "ask_rules")
    assert ret =~ "STR or DEX"

    # Parent's 1/1 + specialist's contributed 8/4 = at least 9/5 (shared usage).
    assert usage.input_tokens >= 9 and usage.output_tokens >= 5
  end

  defp find_return(messages, name) do
    Enum.find_value(messages, fn
      %Message.Request{parts: parts} ->
        Enum.find(parts, &match?(%Part.ToolReturn{tool_name: ^name}, &1))

      _ ->
        nil
    end)
  end
end
