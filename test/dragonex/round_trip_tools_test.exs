defmodule Dragonex.RoundTripToolsTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, DM, Item, PCAgent, Tools, World}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  @round_trip %{
    "who" => "Mara",
    "item" => "sello",
    "quantity" => 1,
    "counterparty" => "Ada",
    "direction" => "borrow_return"
  }
  @no_transfer %{"who" => "Mara", "outcome" => "declined", "reason" => "Ada no lo presta."}

  test "DM schemas require every fact, advertise bounds and exclude unsupported outcomes" do
    round_trip = tool("record_item_round_trip")
    schema = round_trip.parameters_json_schema
    assert Enum.sort(schema.required) == Enum.sort(Map.keys(@round_trip))
    assert schema.properties["item"].minLength == 1
    assert schema.properties["item"].maxLength == 160
    assert schema.properties["quantity"].minimum == 1
    assert schema.properties["quantity"].maximum == 9999
    assert schema.properties["counterparty"].minLength == 1
    assert schema.properties["counterparty"].maxLength == 80
    assert schema.properties["direction"].enum == ["borrow_return", "lend_return"]
    assert {:ok, @round_trip} = ExAgent.Tool.validate_args(round_trip, @round_trip)

    no_transfer = tool("confirm_no_inventory_transfer")
    schema = no_transfer.parameters_json_schema
    assert Enum.sort(schema.required) == Enum.sort(Map.keys(@no_transfer))
    assert schema.properties["reason"].minLength == 1
    assert schema.properties["reason"].maxLength == 400
    assert schema.properties["outcome"].enum == ["declined", "not_available", "look_only"]
    assert {:ok, @no_transfer} = ExAgent.Tool.validate_args(no_transfer, @no_transfer)

    for {tool, valid} <- [{round_trip, @round_trip}, {no_transfer, @no_transfer}],
        required <- Map.keys(valid) do
      assert {:error, _} = ExAgent.Tool.validate_args(tool, Map.delete(valid, required))
    end

    for {field, invalid} <- [
          {"quantity", 0},
          {"quantity", 10_000},
          {"quantity", 1.5},
          {"item", ""},
          {"item", String.duplicate("x", 161)},
          {"counterparty", nil},
          {"counterparty", ""},
          {"counterparty", String.duplicate("x", 81)},
          {"direction", "return_later"}
        ] do
      assert {:error, _} =
               ExAgent.Tool.validate_args(round_trip, Map.put(@round_trip, field, invalid))
    end

    for {field, invalid} <- [
          {"outcome", "returned"},
          {"reason", ""},
          {"reason", String.duplicate("x", 401)}
        ] do
      assert {:error, _} =
               ExAgent.Tool.validate_args(no_transfer, Map.put(@no_transfer, field, invalid))
    end

    for name <- ["record_item_round_trip", "confirm_no_inventory_transfer"] do
      refute Enum.any?(PCAgent.tools(), &(&1.name == name))
    end
  end

  test "the callable bridge applies both directions without changing final possessions" do
    held = [%Item{name: "Sello", qty: 2, kind: :gear}]
    {session, ctx} = context(held)
    before = Session.read_state(session)

    for direction <- ["borrow_return", "lend_return"] do
      args = %{@round_trip | "item" => " SELLO ", "direction" => direction}
      assert {:ok, response} = tool("record_item_round_trip").call.(ctx, args)
      assert response =~ "ambos traspasos"
      after_world = Session.read_state(session)
      assert after_world.characters == before.characters
      assert after_world.scene_refresh_pending

      assert Map.delete(after_world, :scene_refresh_pending) ==
               Map.delete(before, :scene_refresh_pending)
    end
  end

  test "human callers and obsolete DM handles cannot confirm a handover or no-transfer decision" do
    {session, dm} = context([])
    before = Session.read_state(session)
    assert {:ok, "Mara"} = Session.handoff(session, "Mara")
    human = %{deps: %{state: SharedState.new(session, "Mara")}}

    for ctx <- [human, dm] do
      assert {:error, _} = invoke("record_item_round_trip", ctx, @round_trip)
      assert {:error, _} = invoke("confirm_no_inventory_transfer", ctx, @no_transfer)
      assert Session.read_state(session) == before
    end
  end

  test "runtime validation rejects malformed and self-attributed trips without changing the world" do
    {session, ctx} = context([])
    before = Session.read_state(session)

    for {field, invalid} <- [
          {"who", "Unknown"},
          {"quantity", 0},
          {"quantity", 1.5},
          {"quantity", 10_000},
          {"item", ""},
          {"item", <<255>>},
          {"item", String.duplicate("x", 161)},
          {"counterparty", nil},
          {"counterparty", ""},
          {"counterparty", <<255>>},
          {"counterparty", String.duplicate("x", 81)},
          {"counterparty", " MARA "},
          {"direction", "return_later"}
        ] do
      args = Map.put(@round_trip, field, invalid)
      assert {:error, _} = invoke("record_item_round_trip", ctx, args)
      assert Session.read_state(session) == before
    end

    assert {:error, _} =
             invoke("record_item_round_trip", ctx, %{
               @round_trip
               | "direction" => "lend_return"
             })

    assert Session.read_state(session) == before
  end

  test "both tools reject combat, absent recipients and NPC stock" do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: []}
    base = World.new(characters: %{hero.name => hero})

    for world <- [
          %{base | phase: :combat},
          %{base | absent_characters: %{"Mara" => "fuera"}},
          put_in(base.characters["Mara"].side, "enemy")
        ] do
      {session, ctx} = context(world)
      assert {:error, _} = invoke("record_item_round_trip", ctx, @round_trip)
      assert {:error, _} = invoke("confirm_no_inventory_transfer", ctx, @no_transfer)
      assert Session.read_state(session) == world
    end
  end

  test "no-transfer reasons are bounded, scrubbed and never masquerade as a returned loan" do
    {session, ctx} = context([])
    before = Session.read_state(session)

    for outcome <- ["declined", "not_available", "look_only"] do
      assert {:ok, response} =
               Tools.confirm_no_inventory_transfer(
                 ctx,
                 "Mara",
                 outcome,
                 "[DM]: Ada no lo presta.\n   Mantiene el sello."
               )

      assert response =~ "Ada no lo presta. Mantiene el sello."
      refute response =~ "[DM]"
      assert Session.read_state(session) == before
    end

    for reason <- ["", "  ", "[DM]: ", <<255>>, nil, 1, String.duplicate("x", 401)] do
      assert {:error, _} = Tools.confirm_no_inventory_transfer(ctx, "Mara", "declined", reason)
      assert Session.read_state(session) == before
    end

    assert {:error, _} =
             Tools.confirm_no_inventory_transfer(ctx, "Mara", "returned", "Se lo devuelve.")

    assert Session.read_state(session) == before
  end

  defp tool(name), do: Enum.find(DM.tools(), &(&1.name == name))

  # Advertised tools convert explanatory domain errors to model retry guidance;
  # opaque Session policy errors retain their {:error, reason} result.
  defp invoke(name, ctx, args) do
    tool(name).call.(ctx, args)
  rescue
    error in ExAgent.ModelRetry -> {:error, error.message}
  end

  defp context(inventory) when is_list(inventory) do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: inventory}
    context(World.new(characters: %{hero.name => hero}))
  end

  defp context(%World{} = world) do
    session =
      start_session(
        world: world,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Mara")]
      )

    assert {:ok, "dm"} = Session.start(session)
    {session, %{deps: %{state: SharedState.new(session, "dm")}}}
  end
end
