defmodule Dragonex.RestResolutionTest do
  use ExUnit.Case, async: true
  alias Dragonex.Game.RestResolution

  defp dm(names),
    do: %{participant: "dm", tool_results: Map.new(names, &{{&1, %{}}, ["paid"]})}

  test "the DM groups all resting participants in one explicit interval" do
    for tool <- ~w(short_rest long_rest),
        do: assert({:error, _} = RestResolution.validate(dm([]), {tool, %{}}))

    assert :ok = RestResolution.validate(dm([]), {"rest_party", %{}})
    assert :ok = RestResolution.validate(%{participant: "Thane"}, {"short_rest", %{}})
  end

  test "a paid rest cannot be charged again as another rest or elapsed time" do
    for old <- ~w(short_rest long_rest rest_party), new <- ~w(rest_party advance_time) do
      assert {:error, _} = RestResolution.validate(dm([old]), {new, %{}})
    end
  end

  test "an advanced interval cannot be charged again by a rest" do
    assert {:error, _} = RestResolution.validate(dm(["advance_time"]), {"rest_party", %{}})
    assert :ok = RestResolution.validate(dm(["advance_time"]), {"advance_time", %{}})
  end

  test "inventory, narration, invalid attempts and later beats do not block a rest" do
    assert :ok = RestResolution.validate(dm(["grant_item", "narrate"]), {"rest_party", %{}})
    assert :ok = RestResolution.validate(dm(["rest_party"]), {"set_scene", %{}})
    assert :ok = RestResolution.validate(dm([]), {"rest_party", %{}})
    beat = %{dm([]) | tool_results: %{{"rest_party", %{}} => []}}
    assert :ok = RestResolution.validate(beat, {"rest_party", %{}})
  end
end
