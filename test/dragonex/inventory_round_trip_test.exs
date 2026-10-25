defmodule Dragonex.InventoryRoundTripTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Item, World}
  alias Dragonex.Rules.InventoryRoundTrip

  defp world(inventory) do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: inventory}
    World.new(characters: %{hero.name => hero})
  end

  test "borrowing and returning records both factual legs with unchanged final possession" do
    before = world([])

    assert {:ok, final, [received, returned]} =
             InventoryRoundTrip.apply(
               before,
               "Mara",
               "  Sello  ",
               1,
               " A\u0301da ",
               "borrow_return"
             )

    assert final.characters == before.characters
    assert final.scene_refresh_pending

    assert %{
             operation: "grant",
             quantity: 1,
             balance_before: 0,
             balance_after: 1,
             source: "Áda",
             recipient: "Mara",
             item_key: "sello"
           } = received

    assert %{
             operation: "remove",
             quantity: 1,
             balance_before: 1,
             balance_after: 0,
             source: "Mara",
             recipient: "Áda",
             item_key: "sello"
           } = returned
  end

  test "lending a whole stack restores its exact original label and position" do
    inventory = [
      %Item{name: "cuerda", qty: 1, kind: :gear},
      %Item{name: "Sello", qty: 2, kind: :gear},
      %Item{name: "antorcha", qty: 3, kind: :gear}
    ]

    before = world(inventory)

    assert {:ok, final, [lent, recovered]} =
             InventoryRoundTrip.apply(before, "Mara", "SELLO", 2, "Ada", "lend_return")

    assert final.characters == before.characters

    assert %{
             operation: "remove",
             balance_before: 2,
             balance_after: 0,
             source: "Mara",
             recipient: "Ada"
           } = lent

    assert %{
             operation: "grant",
             balance_before: 0,
             balance_after: 2,
             source: "Ada",
             recipient: "Mara"
           } = recovered
  end

  test "temporary additional units preserve an existing stack and legacy duplicates" do
    inventory = [
      %Item{name: "Sello", qty: 2, kind: :gear},
      %Item{name: "SELLO", qty: 3, kind: :gear}
    ]

    before = world(inventory)

    assert {:ok, final, [first, last]} =
             InventoryRoundTrip.apply(before, "Mara", "sello", 1, "Ada", "borrow_return")

    assert final.characters == before.characters
    assert {first.balance_before, first.balance_after} == {5, 6}
    assert {last.balance_before, last.balance_after} == {6, 5}
  end

  test "the second leg must also validate and cannot publish a partially lent item" do
    before =
      world([
        %Item{name: "Sello", qty: 1, kind: :gear},
        %Item{name: "SELLO", qty: 1, kind: :armor}
      ])

    assert {:error, message} =
             InventoryRoundTrip.apply(before, "Mara", "sello", 1, "Ada", "lend_return")

    assert message =~ "solo modifica objetos descriptivos"
    assert length(before.characters["Mara"].inventory) == 2
  end

  test "presence, phase, bounded positive quantity, gear and intermediate capacity remain enforced" do
    empty = world([])
    full = world([%Item{name: "sello", qty: 9999, kind: :gear}])
    weapon = world([%Item{name: "sello", qty: 1, kind: :weapon}])

    for {before, who, quantity, direction} <- [
          {empty, "Ada", 1, "borrow_return"},
          {%{empty | phase: :combat}, "Mara", 1, "borrow_return"},
          {empty, "Mara", 0, "borrow_return"},
          {empty, "Mara", 1.5, "borrow_return"},
          {empty, "Mara", 10000, "borrow_return"},
          {empty, "Mara", 1, "lend_return"},
          {full, "Mara", 1, "borrow_return"},
          {weapon, "Mara", 1, "lend_return"}
        ] do
      assert {:error, _} =
               InventoryRoundTrip.apply(before, who, "sello", quantity, "Ada", direction)
    end

    assert {:error, :invalid_round_trip_direction} =
             InventoryRoundTrip.apply(empty, "Mara", "sello", 1, "Ada", "lend")

    assert {:error, :round_trip_counterparty_required} =
             InventoryRoundTrip.apply(empty, "Mara", "sello", 1, nil, "borrow_return")

    assert {:error, :round_trip_counterparty_required} =
             InventoryRoundTrip.apply(empty, "Mara", "sello", 1, " MARA ", "borrow_return")

    assert {:error, _} =
             InventoryRoundTrip.apply(
               empty,
               "Mara",
               "sello",
               1,
               String.duplicate("a", 81),
               "borrow_return"
             )
  end
end
