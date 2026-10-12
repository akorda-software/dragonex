defmodule Dragonex.ModelsDeepseekRoutingTest do
  use ExUnit.Case, async: false
  alias Dragonex.Models

  setup do
    old = System.get_env("DRAGONEX_DEEPSEEK_PROVIDERS")

    on_exit(fn ->
      if old,
        do: System.put_env("DRAGONEX_DEEPSEEK_PROVIDERS", old),
        else: System.delete_env("DRAGONEX_DEEPSEEK_PROVIDERS")
    end)

    System.delete_env("DRAGONEX_DEEPSEEK_PROVIDERS")
    :ok
  end

  test "DeepSeek stays pinned to Decart unless a strict provider list is configured" do
    assert %{only: ["decart"], allow_fallbacks: false} =
             Models.routing_for("deepseek/deepseek-v4.1-flash")

    System.put_env("DRAGONEX_DEEPSEEK_PROVIDERS", " deepseek, fireworks ")

    assert Models.routing_for("deepseek/deepseek-v4.1-flash") == %{
             order: ["deepseek", "fireworks"],
             only: ["deepseek", "fireworks"],
             allow_fallbacks: false,
             require_parameters: true
           }

    System.put_env("DRAGONEX_DEEPSEEK_PROVIDERS", "  ")
    assert %{only: ["decart"]} = Models.routing_for("deepseek/deepseek-v4.1-flash")
  end
end
