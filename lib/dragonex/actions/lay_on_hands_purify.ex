defmodule Dragonex.Actions.LayOnHandsPurify do
  @moduledoc "D91: combined Lay on Hands healing and explicit purification."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, World}

  def prepare(world, who, target, amount, conditions) do
    caster = World.present_character(world, who)
    recipient = World.present_character(world, target)

    with :ok <- validate(caster, recipient, amount, conditions) do
      applied = min(amount, max(0, recipient.max_hp - recipient.hp))
      cost = applied + 5 * length(conditions)
      remaining = caster.lay_on_hands_pool - cost
      names = Enum.uniq([who, target])
      expected = snapshot(world, names)

      change = fn current ->
        if snapshot(current, names) == expected do
          with {:ok, healed} <- heal_if_needed(current, target, applied),
               {:ok, spent} <- World.set_lay_on_hands_pool(who, remaining).(healed) do
            Enum.reduce_while(conditions, {:ok, spent}, fn condition, {:ok, w} ->
              case World.remove_condition(target, condition).(w) do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end
            end)
          end
        else
          {:error,
           dgettext(
             "engine",
             "Imposición de manos: personajes o plazos han cambiado; vuelve a resolver"
           )}
        end
      end

      {:ok,
       dgettext(
         "engine",
         "%{caster} usa Manos impositoras en %{target}: elimina %{conditions}, cura %{amount} pg y gasta %{cost} puntos (pool %{remaining}).",
         caster: who,
         target: target,
         conditions: Enum.map_join(conditions, ", ", &Dragonex.Terms.condition/1),
         amount: applied,
         cost: cost,
         remaining: remaining
       ), change}
    end
  end

  defp snapshot(world, names),
    do: {Map.take(World.present_characters(world), names), Map.take(world.effect_expiries, names)}

  defp heal_if_needed(world, _, 0), do: {:ok, world}
  defp heal_if_needed(world, target, amount), do: World.heal(target, amount).(world)

  defp validate(nil, _, _, _), do: {:error, dgettext("engine", "no existe el paladín")}

  defp validate(%Character{class: class}, _, _, _) when class != "paladin",
    do: {:error, dgettext("engine", "Imposición de manos requiere un paladín")}

  defp validate(_, nil, _, _), do: {:error, dgettext("engine", "no existe el objetivo")}

  defp validate(_, %Character{death_saves: %{fails: fails}}, _, _) when fails >= 3,
    do: {:error, dgettext("engine", "el objetivo está muerto; Imposición de manos no resucita")}

  defp validate(caster, target, amount, conditions) do
    cond do
      String.downcase(target.race || "") in ["undead", "construct"] ->
        {:error, dgettext("engine", "Imposición de manos no afecta a constructos ni no-muertos")}

      not is_integer(amount) or amount < 0 ->
        {:error, dgettext("engine", "amount debe ser un entero >= 0 al purificar")}

      not is_list(conditions) or conditions == [] ->
        {:error,
         dgettext("engine", "conditions_to_remove debe ser una lista de poisoned y/o diseased")}

      Enum.uniq(conditions) != conditions or
          Enum.any?(conditions, &(&1 not in ["poisoned", "diseased"])) ->
        {:error,
         dgettext("engine", "conditions_to_remove solo admite poisoned y diseased sin duplicados")}

      Enum.any?(conditions, &(&1 not in Character.condition_names(target))) ->
        {:error, dgettext("engine", "el objetivo no tiene todas las condiciones seleccionadas")}

      not is_integer(caster.lay_on_hands_pool) or
          caster.lay_on_hands_pool < amount + 5 * length(conditions) ->
        {:error,
         dgettext(
           "engine",
           "reserva insuficiente: purificar cuesta 5 puntos por condición además de la curación"
         )}

      true ->
        :ok
    end
  end
end
