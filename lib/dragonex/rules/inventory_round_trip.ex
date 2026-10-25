defmodule Dragonex.Rules.InventoryRoundTrip do
  @moduledoc "Two validated, ordered inventory legs with exactly the original final possession."
  alias Dragonex.World
  alias Dragonex.Rules.Inventory

  def apply(world, who, item, quantity, counterparty, direction)
      when direction in ["borrow_return", "lend_return"] do
    with {:ok, partner} when is_binary(partner) <- Inventory.counterparty(counterparty),
         true <- Inventory.key(partner) != Inventory.key(who),
         {:ok, middle} <- first(direction, who, item, quantity).(world),
         {:ok, last} <- second(direction, who, item, quantity).(middle) do
      operations =
        if direction == "borrow_return", do: ["grant", "remove"], else: ["remove", "grant"]

      [first_operation, second_operation] = operations

      legs = [
        leg(world, middle, who, item, partner, first_operation),
        leg(middle, last, who, item, partner, second_operation)
      ]

      # A fully lent stack would otherwise be appended under the call's spelling.
      # Return the exact original stacks, order and labels, not merely their sum.
      original = world.characters[who].inventory
      final = put_in(last.characters[who].inventory, original)
      {:ok, final, legs}
    else
      {:ok, nil} -> {:error, :round_trip_counterparty_required}
      false -> {:error, :round_trip_counterparty_required}
      error -> error
    end
  end

  def apply(_, _, _, _, _, _), do: {:error, :invalid_round_trip_direction}

  # Additional units here are proven temporary units by the paired inverse leg;
  # neither operation equips items or consumes them for a mechanical effect.
  defp first("borrow_return", who, item, quantity),
    do: World.grant_item(who, item, quantity, true)

  defp first("lend_return", who, item, quantity), do: World.remove_item(who, item, quantity)
  defp second("borrow_return", who, item, quantity), do: World.remove_item(who, item, quantity)
  defp second("lend_return", who, item, quantity), do: World.grant_item(who, item, quantity, true)

  defp leg(before, after_world, who, item, partner, operation) do
    old = Inventory.stacks(before.characters[who].inventory, item)
    new = Inventory.stacks(after_world.characters[who].inventory, item)
    old_balance = Enum.sum(Enum.map(old, & &1.qty))
    new_balance = Enum.sum(Enum.map(new, & &1.qty))
    label = hd(old ++ new).name

    %{
      operation: operation,
      stock_owner: who,
      item: label,
      item_key: Inventory.key(item),
      quantity: abs(new_balance - old_balance),
      balance_before: old_balance,
      balance_after: new_balance,
      source: if(operation == "grant", do: partner, else: who),
      recipient: if(operation == "grant", do: who, else: partner),
      counterparty_declared: true
    }
  end
end
