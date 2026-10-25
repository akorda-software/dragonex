defmodule Dragonex.Game.InventoryMovement do
  @moduledoc "Factual inventory deltas saved with the tool's World and replay receipt."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Item, Text, World}
  alias Dragonex.Rules.Inventory

  @max_counterparty 80
  def max_counterparty, do: @max_counterparty

  # A counterparty is the DM's attribution, not an NPC existence check or a
  # second character's inventory mutation. Missing attribution stays unknown.
  def counterparty(nil), do: {:ok, nil}

  def counterparty(value) when is_binary(value) and byte_size(value) <= 512 do
    if String.valid?(value) do
      clean =
        value
        |> String.normalize(:nfc)
        |> Text.scrub()
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      if String.length(clean) in 1..@max_counterparty,
        do: {:ok, clean},
        else: invalid_counterparty()
    else
      invalid_counterparty()
    end
  end

  def counterparty(_), do: invalid_counterparty()

  defp invalid_counterparty do
    {:error,
     dgettext(
       "engine",
       "Indica un origen o destinatario de 1 a %{max} caracteres, o null si no se conoce.",
       max: @max_counterparty
     )}
  end

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

  defp stacks(world, who, key) do
    case world.characters[who] do
      %{inventory: inventory} when is_list(inventory) ->
        Enum.filter(inventory, fn
          %Item{kind: :gear, name: name, qty: qty} when is_integer(qty) and qty > 0 ->
            Inventory.key(name) == key

          _ ->
            false
        end)

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
