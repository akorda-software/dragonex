defmodule Dragonex.ToolArgumentRetryGuidanceTest do
  use ExUnit.Case, async: true
  alias Dragonex.AgentInstructions
  alias Dragonex.Test.ModelMessages
  alias ExAgent.{Message, Message.Part}
  @prefix "REINTENTO DE HERRAMIENTAS:"

  defp state(feedback) do
    %{
      agent: %{instructions: [%Part.System{content: "Rol actual."}]},
      messages: [Message.new_request([%Part.User{content: "Recojo el farol."}])],
      request_messages: nil,
      deps: %{model_retry: feedback}
    }
  end

  defp guides(messages) do
    ModelMessages.project(messages)
    |> Enum.filter(&(&1["role"] == "system" and String.starts_with?(&1["content"], @prefix)))
  end

  test "the rejected-arguments retry gets one schema cue without changing canonical history" do
    original = state(:invalid_tool_arguments)
    projected = AgentInstructions.before_model_request(AgentInstructions, original)
    assert [%{"content" => cue}] = guides(projected.request_messages)
    assert cue =~ "JSON Schema" and cue =~ "contenedor" and cue =~ "confirmados"
    assert projected.messages == original.messages and projected.deps == original.deps
    again = AgentInstructions.before_model_request(AgentInstructions, projected)
    assert again.request_messages == projected.request_messages
    assert guides(original.messages) == []
  end

  test "other errors, malformed flags and first attempts never receive or expose retry feedback" do
    for flag <- [
          nil,
          false,
          :timeout,
          :request_failed,
          "invalid_tool_arguments",
          %{body: "private-provider-response"}
        ] do
      original = state(flag)
      projected = AgentInstructions.before_model_request(AgentInstructions, original)
      assert guides(projected.request_messages) == []
      refute inspect(projected.request_messages) =~ "private-provider-response"
      assert projected.messages == original.messages
    end
  end
end
