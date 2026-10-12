defmodule Dragonex.Rules.Inventory do
  @moduledoc "Bounded descriptive gear stacks; no equipment or consumable effects."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Item, Text}

  @max_name 160
  @max_quantity 9999
  @max_entries 80
  def max_name, do: @max_name
  def max_quantity, do: @max_quantity

  @doc "Fingerprint of the actual world except owned quantities and review/checkpoint bookkeeping."
  def scene_fingerprint(world) do
    characters = Map.new(world.characters, fn {name, c} -> {name, %{c | inventory: []}} end)

    world
    |> Map.put(:characters, characters)
    |> Map.drop([:scene_refresh_pending, :actor_checkpoint])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def key(value) do
    case name(value) do
      {:ok, clean} -> String.downcase(clean)
      _ -> value
    end
  end

  def change(items, item, quantity, operation) do
    with {:ok, name} <- name(item),
         :ok <- quantity(quantity),
         true <- is_list(items) do
      index = Enum.find_index(items, &(key(&1.name) == key(name)))
      update(items, index, name, quantity, operation)
    else
      false -> {:error, dgettext("engine", "Inventario sin registro válido.")}
      error -> error
    end
  end

  defp name(value) when is_binary(value) and byte_size(value) <= 1024 do
    if String.valid?(value) do
      clean =
        value
        |> String.normalize(:nfc)
        |> Text.scrub()
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      if String.length(clean) in 1..@max_name, do: {:ok, clean}, else: invalid_name()
    else
      invalid_name()
    end
  end

  defp name(_), do: invalid_name()

  defp invalid_name,
    do:
      {:error,
       dgettext("engine", "El nombre del objeto debe tener entre 1 y %{max} caracteres.",
         max: @max_name
       )}

  defp quantity(q) when is_integer(q) and q in 1..@max_quantity, do: :ok

  defp quantity(_),
    do:
      {:error,
       dgettext("engine", "La cantidad debe ser un entero entre 1 y %{max}.", max: @max_quantity)}

  defp update(items, nil, name, quantity, :grant) when length(items) < @max_entries,
    do: {:ok, items ++ [%Item{name: name, qty: quantity, kind: :gear}]}

  defp update(_items, nil, _name, _quantity, :grant),
    do:
      {:error,
       dgettext("engine", "El inventario admite hasta %{max} entradas.", max: @max_entries)}

  defp update(_items, nil, _name, _quantity, :remove),
    do: {:error, dgettext("engine", "El personaje no tiene ese objeto en su inventario.")}

  defp update(items, index, _name, quantity, operation) do
    case Enum.at(items, index) do
      %Item{kind: :gear, qty: stock} = item when is_integer(stock) and stock > 0 ->
        total = if operation == :grant, do: stock + quantity, else: stock - quantity

        cond do
          total < 0 ->
            {:error,
             dgettext("engine", "Cantidad insuficiente: tiene %{stock} unidades.", stock: stock)}

          total > @max_quantity ->
            {:error,
             dgettext("engine", "La pila admite hasta %{max} unidades.", max: @max_quantity)}

          total == 0 ->
            {:ok, List.delete_at(items, index)}

          true ->
            {:ok, List.replace_at(items, index, %{item | qty: total})}
        end

      _ ->
        {:error,
         dgettext(
           "engine",
           "Esta herramienta solo modifica objetos descriptivos de equipo; no equipa ni retira armas o armaduras."
         )}
    end
  end
end
