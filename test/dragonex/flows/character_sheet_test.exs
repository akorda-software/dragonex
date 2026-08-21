defmodule Dragonex.Flows.CharacterSheetTest do
  @moduledoc """
  Flow 2 — character sheets as structured output.

  Validates that a DM agent returns a validated `Dragonex.Character` struct: the
  output tool validates via the changeset (level 1-20, ability scores 1-20,
  HP >= 0), and the JSON Schema sent to the model now carries those bounds (so a
  real model would comply). Also covers the retry path: an out-of-range value is
  rejected and the model gets another try.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Character
  alias ExAgent.Message.Part

  @valid_args %{
    "name" => "Lyra",
    "class" => "rogue",
    "level" => 3,
    "hp" => 24,
    "str" => 8,
    "dex" => 17,
    "con" => 14
  }

  test "the DM returns a validated character sheet" do
    model = %ExAgent.Models.Test{
      script: [
        {:tool_calls, [%Part.ToolCall{tool_name: "final_result", args: @valid_args}]}
      ]
    }

    agent = ExAgent.new(model: model, output: Character)

    assert {:ok, %{output: %Character{} = c}} = ExAgent.run(agent, "make a level-3 rogue")
    assert c.name == "Lyra"
    assert c.class == "rogue"
    assert c.level == 3
    assert c.dex == 17
  end

  test "an out-of-range ability score is rejected, then a valid one succeeds" do
    model = %ExAgent.Models.Test{
      script: [
        # str: 25 — outside the 1-20 bound the changeset enforces.
        {:tool_calls,
         [%Part.ToolCall{tool_name: "final_result", args: Map.put(@valid_args, "str", 25)}]},
        # str: 10 — valid on the retry.
        {:tool_calls,
         [%Part.ToolCall{tool_name: "final_result", args: Map.put(@valid_args, "str", 10)}]}
      ]
    }

    agent = ExAgent.new(model: model, output: Character, output_retries: 2)

    assert {:ok, %{output: %Character{str: 10}}} = ExAgent.run(agent, "make a hero")
  end

  test "the derived JSON Schema tells the model the bounds" do
    schema = ExAgent.OutputSchema.json_schema(Character)

    # The validate_number constraints flow into the schema the model sees.
    assert schema.properties["str"] == %{type: "integer", minimum: 1, maximum: 20}
    assert schema.properties["level"] == %{type: "integer", minimum: 1, maximum: 20}
    assert schema.properties["hp"] == %{type: "integer", minimum: 0}
  end
end
