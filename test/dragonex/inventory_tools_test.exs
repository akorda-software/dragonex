defmodule Dragonex.InventoryToolsTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, DM, PCAgent, Tools, World}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  test "only the DM can confirm inventory changes through the current shared state" do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: []}

    session =
      start_session(
        world: World.new(characters: %{hero.name => hero}),
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Mara")]
      )

    assert {:ok, "dm"} = Session.start(session)
    ctx = %{deps: %{state: SharedState.new(session, "dm")}}
    assert {:ok, _} = Tools.grant_item(ctx, "Mara", "botón de latón", 2, nil)
    assert [%{qty: 2}] = Session.read_state(session).characters["Mara"].inventory
    assert {:ok, _} = Tools.remove_item(ctx, "Mara", "botón de latón", 1)
    saved = Session.read_state(session)
    assert [%{qty: 1}] = saved.characters["Mara"].inventory

    for invalid <- ["", String.duplicate("a", 81), <<255>>, 10] do
      assert {:error, _} = Tools.grant_item(ctx, "Mara", "otro botón", 1, nil, invalid)
      assert {:error, _} = Tools.remove_item(ctx, "Mara", "botón de latón", 1, invalid)
      assert Session.read_state(session) == saved
    end

    assert {:ok, "Mara"} = Session.handoff(session, "Mara")
    pc = %{deps: %{state: SharedState.new(session, "Mara")}}
    assert {:error, _} = Tools.grant_item(pc, "Mara", "botón", 1, nil)
    assert {:error, _} = Tools.remove_item(pc, "Mara", "botón de latón", 1)
    assert Session.read_state(session) == saved
  end

  test "the model schema advertises actual bounds and these tools belong only to the DM" do
    for name <- ["grant_item", "remove_item"] do
      tool = Enum.find(DM.tools(), &(&1.name == name))
      assert tool != nil
      assert tool.parameters_json_schema.properties["item"].maxLength == 160
      assert tool.parameters_json_schema.properties["quantity"].minimum == 1
      assert tool.parameters_json_schema.properties["quantity"].maximum == 9999
      counterparty = if name == "grant_item", do: "source", else: "recipient"
      assert tool.parameters_json_schema.properties[counterparty].type == ["string", "null"]
      assert tool.parameters_json_schema.properties[counterparty].maxLength == 80
      args = %{"who" => "Mara", "item" => "sello", "quantity" => 1}

      if name == "remove_item" do
        assert counterparty in tool.parameters_json_schema.required
        assert {:error, errors} = ExAgent.Tool.validate_args(tool, args)
        assert Enum.any?(errors, &(&1.keyword == "required"))
      else
        refute counterparty in tool.parameters_json_schema.required
        assert {:ok, ^args} = ExAgent.Tool.validate_args(tool, args)
      end

      for recipient <- [nil, "Ada"] do
        explicit = Map.put(args, counterparty, recipient)
        assert {:ok, ^explicit} = ExAgent.Tool.validate_args(tool, explicit)
      end

      refute Enum.any?(PCAgent.tools(), &(&1.name == name))
    end
  end
end
