defmodule Dragonex.ClassResources do
  @moduledoc """
  Capacidad de los pools de clase y su ampliación al progresar.

  Subir añade capacidad nueva a la reserva viva: no repone los puntos/usos
  gastados ni marca un descanso. Se comparte entre LevelUp, merge de partida
  y lectura de la ficha/brief; no accede a DB ni añade campos a Character.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Character
  alias Dragonex.Heroes.Progression
  alias Dragonex.Rules.Ability

  @pools ~w(ki sorcery_points lay_on_hands_pool divine_sense_uses bardic_inspiration_uses
    wild_shape_uses)a

  @doc "Máximos de los pools finitos modelados para esta clase y nivel."
  @spec capacities(Character.t()) :: %{optional(atom()) => non_neg_integer()}
  def capacities(%Character{class: "monk", level: level}),
    do: %{ki: Progression.ki_points("monk", level)}

  def capacities(%Character{class: "sorcerer", level: level}),
    do: %{sorcery_points: Progression.sorcery_points("sorcerer", level)}

  def capacities(%Character{class: "paladin", level: level, cha: cha}),
    do: %{lay_on_hands_pool: 5 * level, divine_sense_uses: max(1, 1 + Ability.modifier(cha))}

  def capacities(%Character{class: "bard", cha: cha}),
    do: %{bardic_inspiration_uses: max(1, Ability.modifier(cha))}

  def capacities(%Character{class: "druid", level: level}),
    do: %{wild_shape_uses: if(level >= 2, do: 2, else: 0)}

  def capacities(%Character{}), do: %{}

  defp label(:ki), do: dgettext("engine", "Ki")
  defp label(:sorcery_points), do: dgettext("engine", "Puntos de hechicería")
  defp label(:lay_on_hands_pool), do: dgettext("engine", "Imposición de manos")
  defp label(:divine_sense_uses), do: dgettext("engine", "Sentido divino")
  defp label(:bardic_inspiration_uses), do: dgettext("engine", "Inspiración bárdica")
  defp label(:wild_shape_uses), do: dgettext("engine", "Forma salvaje")

  @doc "Reservas desbloqueadas de la ficha viva, compartidas por mesa y agentes."
  @spec pools(Character.t()) :: [map()]
  def pools(%Character{} = character) do
    capacities = capacities(character)

    for field <- @pools,
        capacity = Map.get(capacities, field, 0),
        capacity > 0 do
      remaining = Map.get(character, field)

      %{
        field: field,
        label: label(field),
        capacity: capacity,
        remaining: if(is_integer(remaining) and remaining >= 0, do: remaining, else: 0)
      }
    end
  end

  @doc "Amplía cada pool desde el gasto de la ficha previa, sin recargarlo."
  @spec level_up(Character.t(), Character.t()) :: Character.t()
  def level_up(%Character{} = previous, %Character{} = updated) do
    old_capacities = capacities(previous)

    Enum.reduce(capacities(updated), updated, fn {field, capacity}, next ->
      current = Map.get(previous, field)
      remaining = if is_integer(current) and current >= 0, do: current, else: 0
      gained = max(0, capacity - Map.get(old_capacities, field, 0))
      Map.put(next, field, remaining + gained)
    end)
  end
end
