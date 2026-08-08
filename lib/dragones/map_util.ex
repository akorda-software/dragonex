defmodule Dragones.MapUtil do
  @moduledoc """
  Helpers para leer mapas que vienen de JSONB (claves `string`) o de structs
  Elixir (claves `atom`), sin distinción.

  Se usa en los puntos donde una `definition` custom puede llegar con claves
  string (desde Postgres) o atom (en runtime): el builder, el catálogo y la
  validación de `CustomContent`.
  """

  @doc """
  Lee `key` de `map` probando primero la clave tal cual y luego su forma atom
  (o viceversa). Usa `Map.get/3` con default (no `||`) para **no perder valores
  falsy** como `finesse: false`.
  """
  @spec get(map(), atom() | String.t(), term()) :: term()
  def get(map, key, default \\ nil) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_other_form(key), default)
      v -> v
    end
  end

  # Devuelve la clave en la otra forma (atom ↔ string).
  defp to_other_form(key) when is_atom(key), do: Atom.to_string(key)
  defp to_other_form(key) when is_binary(key), do: String.to_atom(key)

  @doc """
  Convierte a atom existente un valor acotado (abilities, kinds). Cae al propio
  valor si no es binario, y a `nil` si el atom no existe (sin inflar la tabla).
  """
  @spec to_atom(atom() | String.t()) :: atom() | nil
  def to_atom(v) when is_atom(v), do: v

  def to_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> nil
  end

  def to_atom(_), do: nil
end
