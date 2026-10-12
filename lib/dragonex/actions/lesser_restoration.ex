defmodule Dragonex.Actions.LesserRestoration do
  @moduledoc "Lesser Restoration (D90): remove one chosen condition per target."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, Terms, World}
  @conditions ~w(blinded deafened paralyzed poisoned diseased)

  def prepare(world, caster, targets, selection) do
    with :ok <- validate_selection(selection),
         :ok <- unique_targets(targets),
         {:ok, choices} <- choose_targets(world, targets, selection) do
      expected = snapshot(world, targets)

      change = fn current ->
        if snapshot(current, targets) == expected do
          Enum.reduce_while(choices, {:ok, current}, fn {name, condition}, {:ok, w} ->
            case World.remove_condition(name, condition).(w) do
              {:ok, next} -> {:cont, {:ok, next}}
              error -> {:halt, error}
            end
          end)
        else
          {:error,
           dgettext(
             "engine",
             "los objetivos de %{spell} han cambiado; vuelve a resolver el hechizo",
             spell: spell()
           )}
        end
      end

      description =
        Enum.map_join(choices, "; ", fn {name, condition} ->
          dgettext("engine", "%{target}: elimina %{condition}",
            target: name,
            condition: Terms.condition(condition)
          )
        end)

      {:ok,
       dgettext("engine", "%{caster} conjura %{spell}; %{effects}.",
         caster: caster,
         spell: spell(),
         effects: description
       ), change}
    end
  end

  defp snapshot(world, targets),
    do:
      {Map.take(World.present_characters(world), targets),
       Map.take(world.effect_expiries, targets)}

  defp validate_selection(selection) when is_nil(selection) or selection in @conditions, do: :ok

  defp validate_selection(_),
    do:
      {:error,
       dgettext(
         "engine",
         "condition_to_remove debe ser blinded, deafened, paralyzed, poisoned o diseased"
       )}

  defp unique_targets(targets) do
    if Enum.uniq(targets) == targets,
      do: :ok,
      else:
        {:error,
         dgettext("engine", "%{spell} requiere objetivos distintos para Twinned", spell: spell())}
  end

  defp choose_targets(world, targets, selection) do
    Enum.reduce_while(targets, {:ok, []}, fn name, {:ok, choices} ->
      case choose(World.present_character(world, name), selection) do
        {:ok, condition} -> {:cont, {:ok, choices ++ [{name, condition}]}}
        {:error, reason} -> {:halt, {:error, "#{name}: #{reason}"}}
      end
    end)
  end

  defp choose(nil, _), do: {:error, dgettext("engine", "no existe el objetivo")}

  defp choose(%Character{death_saves: %{fails: fails}}, _) when fails >= 3,
    do: {:error, dgettext("engine", "está muerto; %{spell} no resucita", spell: spell())}

  defp choose(target, selection) do
    eligible = Enum.filter(@conditions, &(&1 in Character.condition_names(target)))

    case {selection, eligible} do
      {nil, [condition]} ->
        {:ok, condition}

      {nil, []} ->
        {:error,
         dgettext("engine", "no tiene ninguna condición que %{spell} pueda eliminar",
           spell: spell()
         )}

      {nil, _} ->
        {:error,
         dgettext("engine", "elige condition_to_remove: %{options}",
           options: Enum.join(eligible, ", ")
         )}

      {condition, _} ->
        if condition in eligible,
          do: {:ok, condition},
          else:
            {:error,
             dgettext("engine", "no tiene la condición %{condition}",
               condition: Terms.condition(condition)
             )}
    end
  end

  defp spell, do: Terms.spell("lesser restoration")
end
