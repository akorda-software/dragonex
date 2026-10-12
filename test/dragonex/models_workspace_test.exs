defmodule Dragonex.ModelsWorkspaceTest do
  use ExUnit.Case, async: true
  alias Dragonex.Models

  test "world codec refuses incomplete or invalid state instead of restoring an empty game" do
    for data <- [
          nil,
          %{},
          %{"phase" => "other", "characters" => %{}},
          %{"phase" => "combat", "characters" => []}
        ] do
      assert Dragonex.Store.WorldCodec.decode(data) == {:error, :invalid_world}
    end

    world = Dragonex.World.new()
    assert {:ok, encoded} = Dragonex.Store.WorldCodec.encode(world)
    assert {:ok, ^world} = Dragonex.Store.WorldCodec.decode(encoded)
  end

  test "the requested models pin their provider and refuse fallback" do
    for {id, provider} <- [
          {"deepseek/deepseek-v4.1-flash", "decart"},
          {"xiaomi/mimo-v2.6-flash", "io-net"}
        ] do
      assert Models.routing_for(id) == %{
               order: [provider],
               only: [provider],
               allow_fallbacks: false,
               require_parameters: true
             }
    end
  end

  test "v2 uses stock routing and a truthful none profile without legacy extras" do
    metadata = %{
      "supported_parameters" => ["tools", "reasoning_effort"],
      "reasoning" => %{"mandatory" => false}
    }

    model =
      Models.chat_model(:openrouter, "deepseek/deepseek-v4.1-flash", "synthetic", metadata)

    assert model.tool_profile == :openrouter_chat_tools_v1
    assert model.reasoning_mode == :none

    assert model.provider_options[:openrouter_provider] ==
             Models.routing_for("deepseek/deepseek-v4.1-flash")

    assert Models.request_settings(model, [max_tokens: 128, temperature: 0], %{
             "reasoning" => %{"effort" => "high"}
           }) == [max_tokens: 128]
  end

  test "unsupported, mandatory and enabled-only reasoning fail before any provider request" do
    for metadata <- [
          %{"supported_parameters" => []},
          %{
            "supported_parameters" => ["tools", "reasoning_effort"],
            "reasoning" => %{"mandatory" => true}
          },
          %{
            "supported_parameters" => ["tools", "reasoning"],
            "reasoning" => %{"mandatory" => false}
          }
        ] do
      assert_raise ArgumentError, fn ->
        Models.chat_model(:openrouter, "xiaomi/mimo-v2.6-flash", "synthetic", metadata)
      end
    end
  end
end
