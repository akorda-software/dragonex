defmodule Dragonex.Actions.HealSpell do
  @moduledoc "Heal (D87): flat healing and explicit condition removal, without dice."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, World}

  @conditions ~w(blinded deafened diseased)

  def prepare(world, caster, targets, level) do
    amount = 70 + 10 * (level - 6)

    with :ok <- unique_targets(targets),
         :ok <- validate_targets(world, targets) do
      expected = Map.take(World.present_characters(world), targets)

      descriptions =
        Enum.map_join(targets, "; ", fn name ->
          target = World.present_character(world, name)
          healed = min(amount, max(0, target.max_hp - target.hp))
          removed = Enum.filter(@conditions, &(&1 in Character.condition_names(target)))

          if removed == [],
            do:
              dgettext("engine", "%{target} recupera %{amount} pg", target: name, amount: healed),
            else:
              dgettext("engine", "%{target} recupera %{amount} pg; elimina %{conditions}",
                target: name,
                amount: healed,
                conditions: Enum.join(removed, ", ")
              )
        end)

      change = fn current ->
        if Map.take(World.present_characters(current), targets) == expected do
          Enum.reduce_while(targets, {:ok, current}, fn target, {:ok, w} ->
            with {:ok, healed} <- World.heal(target, amount).(w) do
              result =
                Enum.reduce(@conditions, healed, fn condition, acc ->
                  {:ok, next} = World.remove_condition(target, condition).(acc)
                  next
                end)

              {:cont, {:ok, result}}
            else
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

      {:ok,
       dgettext("engine", "%{caster} conjura %{spell}; %{effects}.",
         caster: caster,
         spell: spell(),
         effects: descriptions
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

  defp validate_targets(world, targets) do
    Enum.reduce_while(targets, :ok, fn name, :ok ->
      case World.present_character(world, name) do
        nil ->
          {:halt, {:error, dgettext("engine", "no existe el objetivo: %{name}", name: name)}}

        %Character{death_saves: %{fails: fails}} when fails >= 3 ->
          {:halt,
           {:error,
            dgettext("engine", "%{name} está muerto; la curación no resucita", name: name)}}

        target ->
          if String.downcase(target.race || "") in ["undead", "construct"] do
            {:halt,
             {:error,
              dgettext("engine", "%{spell} no afecta a constructos ni no-muertos: %{target}",
                spell: spell(),
                target: name
              )}}
          else
            {:cont, :ok}
          end
      end
    end)
  end

  defp spell, do: Dragonex.Terms.spell("heal")
end
