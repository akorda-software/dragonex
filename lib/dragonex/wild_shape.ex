defmodule Dragonex.WildShape do
  @moduledoc """
  Lectura de la forma original y preservación de la bestia durante progresión.

  La subida modifica el druida guardado dentro de `wild_shape`; los PG y las
  estadísticas físicas de la bestia siguen siendo su estado vivo. Es puro y
  usa los campos existentes del snapshot D63, sin cambiar Character ni Codec.
  """

  alias Dragonex.Character

  @beast_names %{"cat" => "gato", "wolf" => "lobo", "black_bear" => "oso negro"}

  @doc "Nombre de la bestia para los resultados del motor y la ficha de partida."
  @spec beast_name(term()) :: String.t()
  def beast_name(beast), do: Map.get(@beast_names, beast, "bestia")

  @doc "Ficha de la forma original, conservando el resto del estado vivo."
  @spec base_form(Character.t()) :: Character.t()
  def base_form(%Character{wild_shape: %{} = saved} = character) do
    %{
      character
      | str: saved[:orig_str],
        dex: saved[:orig_dex],
        con: saved[:orig_con],
        hp: saved[:orig_hp] || 0,
        max_hp: saved[:orig_max_hp],
        ac: saved[:orig_ac],
        weapons: saved[:orig_weapons] || [],
        wild_shape: nil
    }
  end

  def base_form(%Character{} = character), do: character

  @doc "Actualiza la forma original progresada conservando la bestia activa."
  @spec preserve_form(Character.t(), Character.t()) :: Character.t()
  def preserve_form(%Character{} = base, %Character{wild_shape: %{} = saved} = active) do
    saved =
      Map.merge(saved, %{
        orig_str: base.str,
        orig_dex: base.dex,
        orig_con: base.con,
        orig_hp: base.hp,
        orig_max_hp: base.max_hp,
        orig_ac: base.ac,
        orig_weapons: base.weapons
      })

    %{
      base
      | str: active.str,
        dex: active.dex,
        con: active.con,
        hp: active.hp,
        max_hp: active.max_hp,
        ac: active.ac,
        weapons: active.weapons,
        wild_shape: saved
    }
  end

  def preserve_form(%Character{} = base, %Character{}), do: base
end
