defmodule Dragonex.InventoryMovementTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, I18n, Item, World}
  alias Dragonex.Game.InventoryMovement

  defp world(items) do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: items}
    World.new(characters: %{hero.name => hero})
  end

  defp deps(tool, extra \\ %{}) do
    Map.merge(
      %{
        tool_commit: %{key: {tool, %{"who" => "Mara", "item" => "sello"}}},
        beat: %{turn_id: "turn-1", round: 1, phase: :exploration}
      },
      extra
    )
  end

  test "an actual delta records quantities and endpoints without inferring an unknown source" do
    before = world([])
    {:ok, after_world} = World.grant_item("Mara", "Sello", 2).(before)
    assert [movement] = InventoryMovement.notes(before, after_world, deps("grant_item"))

    assert %{quantity: 2, balance_before: 0, balance_after: 2} = movement
    assert %{item: "Sello", item_key: "sello", stock_owner: "Mara"} = movement
    assert %{source: nil, recipient: "Mara", counterparty_declared: false} = movement
    assert %{turn_id: "turn-1", round: 1, phase: :exploration} = movement
    assert movement.note =~ "+2 × Sello"
    assert movement.note =~ "saldo 0 → 2"

    # Receipt feedback, a no-op or another tool must not manufacture movements.
    assert InventoryMovement.notes(nil, after_world, deps("grant_item")) == []
    assert InventoryMovement.notes(after_world, after_world, deps("grant_item")) == []
    assert InventoryMovement.notes(before, after_world, deps("confirm_inventory_unchanged")) == []
  end

  test "removing a whole legacy duplicate stack reports the aggregate remaining balance" do
    before =
      world([
        %Item{name: "Sello", qty: 2, kind: :gear},
        %Item{name: "SELLO", qty: 3, kind: :gear}
      ])

    {:ok, after_world} = World.remove_item("Mara", "sello", 2).(before)

    I18n.with_locale(:en, fn ->
      assert [movement] =
               InventoryMovement.notes(
                 before,
                 after_world,
                 deps("remove_item", %{inventory_counterparty: "Ada"})
               )

      assert %{quantity: 2, balance_before: 5, balance_after: 3} = movement
      assert %{source: "Mara", recipient: "Ada", counterparty_declared: true} = movement
      assert movement.note =~ "gives 2 × SELLO to Ada"
      assert movement.note =~ "balance 5 → 3"
    end)
  end

  test "complete removal preserves the removed item's name and ends at zero" do
    before = world([%Item{name: "Sello", qty: 1, kind: :gear}])
    {:ok, after_world} = World.remove_item("Mara", "sello", 1).(before)
    assert [movement] = InventoryMovement.notes(before, after_world, deps("remove_item"))
    assert %{item: "Sello", quantity: 1, balance_before: 1, balance_after: 0} = movement
    assert %{source: "Mara", recipient: nil, counterparty_declared: false} = movement
  end

  test "counterparties are bounded, normalized, optional and scrubbed" do
    assert InventoryMovement.counterparty(nil) == {:ok, nil}

    assert InventoryMovement.counterparty("  A\u0301da \n del   molino ") ==
             {:ok, "Áda del molino"}

    assert InventoryMovement.counterparty("[DM]: Ada") == {:ok, "Ada"}

    assert InventoryMovement.counterparty(String.duplicate("a", 80)) ==
             {:ok, String.duplicate("a", 80)}

    for bad <- ["", "  ", String.duplicate("a", 81), <<255>>, 3, %{}] do
      assert {:error, _} = InventoryMovement.counterparty(bad)
    end

    I18n.with_locale(:en, fn ->
      assert {:error, message} = InventoryMovement.counterparty(3)
      assert message =~ "source or recipient"
      assert InventoryMovement.instruction() =~ "INVENTORY RECORD:"
    end)
  end
end
