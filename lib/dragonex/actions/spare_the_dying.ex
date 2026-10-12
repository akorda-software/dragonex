defmodule Dragonex.Actions.SpareTheDying do
  @moduledoc "Spare the Dying (D88): stabilize living targets without rolling or healing."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.World

  def prepare(world, caster, targets) do
    with :ok <- unique_targets(targets),
         {:ok, _preview} <- stabilize_targets(world, targets) do
      expected = Map.take(World.present_characters(world), targets)

      change = fn current ->
        if Map.take(World.present_characters(current), targets) == expected,
          do: stabilize_targets(current, targets),
          else:
            {:error,
             dgettext("engine", "los objetivos han cambiado; vuelve a resolver %{spell}",
               spell: spell()
             )}
      end

      message =
        Enum.map_join(
          targets,
          "; ",
          &dgettext("engine", "%{target} queda estable a 0 pg", target: &1)
        )

      {:ok,
       dgettext("engine", "%{caster} conjura %{spell}; %{effects}.",
         caster: caster,
         spell: spell(),
         effects: message
       ), change}
    end
  end

  defp unique_targets(targets) do
    if Enum.uniq(targets) == targets,
      do: :ok,
      else:
        {:error,
         dgettext("engine", "%{spell} requiere objetivos distintos para Twinned", spell: spell())}
  end

  defp stabilize_targets(world, targets) do
    Enum.reduce_while(targets, {:ok, world}, fn target, {:ok, w} ->
      character = World.present_character(w, target)

      result =
        cond do
          is_nil(character) ->
            {:error,
             dgettext("engine", "no existe el objetivo presente: %{target}", target: target)}

          String.downcase(character.race || "") in ["undead", "construct"] ->
            {:error,
             dgettext(
               "engine",
               "%{spell} no afecta a constructos ni no-muertos: %{target}",
               spell: spell(),
               target: target
             )}

          true ->
            World.stabilize(target).(w)
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp spell, do: Dragonex.Terms.spell("spare the dying")
end
