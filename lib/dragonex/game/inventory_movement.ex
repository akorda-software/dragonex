defmodule Dragonex.Game.InventoryMovement do
  @moduledoc "Factual inventory deltas saved with the tool's World and replay receipt."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Text, World}
  alias Dragonex.Rules.Inventory

  # A counterparty is the DM's attribution, not an NPC existence check or a
  # second character's inventory mutation. Missing attribution stays unknown.
  defdelegate max_counterparty(), to: Inventory
  defdelegate counterparty(value), to: Inventory

  def instruction do
    dgettext(
      "prompts",
      "TRAZA DE INVENTARIO: en grant_item indica source si conoces quién entrega o de dónde procede el objeto; source se puede omitir. En remove_item SIEMPRE incluye recipient: nombre o rol de quien recibe el objeto, o null únicamente si no hay receptor o se desconoce. Son atribuciones breves del DM, no personajes creados ni cambios en otro inventario. No inventes una contraparte. El motor registra el objeto, la cantidad y el saldo real. Al recuperar una herramienta ya aplicada, conserva su movimiento original."
    )
  end

  # Only the actual commit has a before World. Replacing a placeholder receipt
  # with tool feedback has none, and a replay never invokes this effect again.
  def notes(
        %World{} = before,
        %World{} = after_world,
        %{tool_commit: %{key: {tool, args}}} = deps
      )
      when tool in ["grant_item", "remove_item"] do
    who = args["who"]
    key = Inventory.key(args["item"])
    old = stacks(before, who, key)
    new = stacks(after_world, who, key)
    balance_before = stock(old)
    balance_after = stock(new)
    delta = balance_after - balance_before

    if delta != 0 do
      item = Text.scrub(hd(new ++ old).name)
      counterparty = Map.get(deps, :inventory_counterparty)
      operation = if delta > 0, do: "grant", else: "remove"
      source = if delta > 0, do: counterparty, else: who
      recipient = if delta > 0, do: who, else: counterparty

      payload = %{
        kind: "inventory_movement",
        operation: operation,
        tool: tool,
        stock_owner: who,
        item: item,
        item_key: key,
        quantity: abs(delta),
        balance_before: balance_before,
        balance_after: balance_after,
        source: source,
        recipient: recipient,
        counterparty_declared: not is_nil(counterparty),
        note: note(who, item, delta, balance_before, balance_after, counterparty)
      }

      [Map.merge(payload, Map.take(Map.get(deps, :beat, %{}), [:turn_id, :round, :phase]))]
    else
      []
    end
  end

  def notes(_, _, _), do: []

  @doc "Materialize the two factual legs returned by the domain inside the writer."
  def round_trip_notes([], _deps), do: []

  def round_trip_notes(legs, deps) do
    group = Ecto.UUID.generate()
    metadata = Map.take(Map.get(deps, :beat, %{}), [:turn_id, :round, :phase])

    legs
    |> Enum.with_index(1)
    |> Enum.map(fn {leg, index} ->
      partner = if leg.operation == "grant", do: leg.source, else: leg.recipient
      delta = leg.balance_after - leg.balance_before

      leg
      |> Map.update!(:item, &Text.scrub/1)
      |> Map.merge(metadata)
      |> Map.merge(%{
        kind: "inventory_movement",
        tool: "record_item_round_trip",
        movement_group: group,
        leg_index: index,
        note:
          note(
            leg.stock_owner,
            Text.scrub(leg.item),
            delta,
            leg.balance_before,
            leg.balance_after,
            partner
          )
      })
    end)
  end

  def no_transfer_notes(
        %{inventory_no_transfer: %{who: who, outcome: outcome, reason: reason}} = deps
      ) do
    [
      %{
        kind: "inventory_no_transfer",
        stock_owner: who,
        outcome: outcome,
        reason: reason,
        note:
          dgettext("engine", "Inventario · %{who}: no cambia de manos ningún objeto. %{reason}",
            who: Text.scrub(who),
            reason: Text.scrub(reason)
          )
      }
      |> Map.merge(Map.take(Map.get(deps, :beat, %{}), [:turn_id, :round, :phase]))
    ]
  end

  def no_transfer_notes(_), do: []

  defp stacks(world, who, key) do
    case world.characters[who] do
      %{inventory: inventory} when is_list(inventory) ->
        Inventory.stacks(inventory, key)

      _ ->
        []
    end
  end

  # Old sheets can have multiple stacks with the same canonical name. Removing
  # the first must not mistake the next stack's quantity for the final balance.
  defp stock(stacks), do: Enum.sum(Enum.map(stacks, & &1.qty))

  defp note(who, item, delta, before, after_balance, nil) do
    dgettext(
      "engine",
      "Inventario · %{who}: %{sign}%{quantity} × %{item}; saldo %{before} → %{after}.",
      who: Text.scrub(who),
      sign: if(delta > 0, do: "+", else: "−"),
      quantity: abs(delta),
      item: item,
      before: before,
      after: after_balance
    )
  end

  defp note(who, item, delta, before, after_balance, counterparty) when delta > 0 do
    dgettext(
      "engine",
      "Inventario · %{who} recibe %{quantity} × %{item} de %{source}; saldo %{before} → %{after}.",
      who: Text.scrub(who),
      quantity: delta,
      item: item,
      source: counterparty,
      before: before,
      after: after_balance
    )
  end

  defp note(who, item, delta, before, after_balance, counterparty) do
    dgettext(
      "engine",
      "Inventario · %{who} entrega %{quantity} × %{item} a %{recipient}; saldo %{before} → %{after}.",
      who: Text.scrub(who),
      quantity: -delta,
      item: item,
      recipient: counterparty,
      before: before,
      after: after_balance
    )
  end
end
