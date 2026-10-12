defmodule Dragonex.Rules.Cantrips do
  @moduledoc """
  Escalado RAW de trucos por NIVEL DE PERSONAJE (ADR D95).

  D74 prohíbe lanzar trucos a nivel superior (no hay eje `cast_level`), así
  que el único escalado de un truco es el del nivel del lanzador: umbrales RAW
  5/11/17 → 2/3/4 dados. La tabla vive aquí, curada en código, con las caras
  base de cada truco (mismo criterio que `Rules.Upcast` D74: el JSON del SRD
  no trae reglas estructuradas de escalado).

  Eldritch Blast: RAW añade rayos (tiradas separadas); el motor lo simplifica
  a DADOS EXTRA sobre una sola tirada (1d10→2d10→3d10→4d10). Simplificación
  documentada en D95, no oculta.

  Módulo puro, testeable con `async: true`.
  """

  alias Dragonex.Spell

  # Caras del dado base por truco (nombre normalizado sin espacios). Solo
  # los trucos de daño de la tabla escalan; cualquier otro hechizo de nivel
  # 0 (light, mage hand…) no se toca.
  @base_dice %{
    "firebolt" => 10,
    "eldritchblast" => 10,
    "rayoffrost" => 8,
    "chilltouch" => 8,
    "produceflame" => 8,
    "shockinggrasp" => 8,
    "sacredflame" => 8,
    "poisonspray" => 12,
    "viciousmockery" => 4,
    "acidsplash" => 6
  }

  @doc "Dados del truco (p. ej. `\"2d10\"`) al nivel de personaje dado. `nil` si el hechizo no está en la tabla."
  @spec scaled_dice(String.t(), non_neg_integer() | nil) :: String.t() | nil
  def scaled_dice(spell_name, caster_level)
      when is_binary(spell_name) and (is_integer(caster_level) or is_nil(caster_level)) do
    case Map.get(@base_dice, normalize(spell_name)) do
      nil ->
        nil

      sides ->
        "#{dice_count(caster_level || 1)}d#{sides}"
    end
  end

  @doc """
  Escala el `dice` del hechizo cuando es un truco de la tabla: reemplaza la
  expresión completa (la hoja trae la base sin escalar, y las hojas rancias
  pueden traer datos del SRD pre-builtin). Cualquier otro hechizo sale
  intacto — `Rules.Upcast` sigue siendo el único eje de escalado por casilla.
  """
  @spec scaled_spell(Spell.t(), non_neg_integer() | nil) :: Spell.t()
  def scaled_spell(%Spell{level: 0, kind: kind} = spell, caster_level)
      when kind in [:attack, :save] do
    case scaled_dice(spell.name, caster_level) do
      nil -> spell
      dice -> %{spell | dice: dice}
    end
  end

  def scaled_spell(%Spell{} = spell, _caster_level), do: spell

  defp dice_count(level) do
    cond do
      level >= 17 -> 4
      level >= 11 -> 3
      level >= 5 -> 2
      true -> 1
    end
  end

  defp normalize(name), do: name |> String.downcase() |> String.replace(~r/[\s_-]+/, "")
end
