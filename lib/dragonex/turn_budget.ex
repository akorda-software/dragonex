defmodule Dragonex.TurnBudget do
  @moduledoc "Durable action/bonus/reaction budgets, refreshed only on a new personal turn."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.World

  def start(w, who) do
    state = Map.get(w.turn_state, who, %{})

    if state["round"] == w.round do
      w
    else
      fresh = %{"round" => w.round, "damaged" => state["damaged"] == true}
      %{w | turn_state: Map.put(w.turn_state, who, fresh)}
    end
  end

  @doc """
  What `who` still has this round, for the table: action and bonus action
  belong to their own turn (spent or ended this round), the reaction lasts
  until their next turn starts. `nil` outside combat.
  """
  def remaining(%{phase: :combat, turn_state: turn_state, round: round}, who) do
    state = Map.get(turn_state || %{}, who, %{})
    own_turn_over? = state["round"] == round and state["ended"] == true

    used? = fn slot -> own_turn_over? or (state["round"] == round and state[slot] == true) end

    %{
      action: not used?.("action"),
      bonus: not used?.("bonus"),
      reaction: state["reaction"] != true
    }
  end

  def remaining(_world, _who), do: nil

  def check(%{phase: phase}, _who, _cost) when phase != :combat, do: :ok
  def check(w, who, {:delegated, cost}), do: check(w, who, cost)

  def check(w, who, cost) do
    state = Map.get(w.turn_state, who, %{})
    slot = slot(cost)
    current = w.current_combatant || List.first(w.initiative_order)

    cond do
      w.turn_kind == "reaction" and slot != "reaction" ->
        {:error, dgettext("engine", "un turno de reacción no concede acción ni acción adicional")}

      slot != "reaction" and current != nil and current != who ->
        {:error,
         dgettext(
           "engine",
           "%{who} no está en su turno; el combatiente actual es %{current}. " <>
             "Termina la narración de %{current} sin ejecutar acciones de otros combatientes. " <>
             "El TurnMaster dará el relevo después de este beat.",
           who: who,
           current: current
         )}

      slot != "reaction" and state["ended"] == true ->
        {:error, dgettext("engine", "el turno de %{who} ya ha terminado", who: who)}

      slot != nil and state[slot] == true ->
        {:error, spent(who, slot)}

      cost == :flurry and state["attacked"] != true ->
        {:error, dgettext("engine", "Ráfaga de golpes requiere la acción de Ataque este turno")}

      cost == :surge and World.character(w, who).action_surge_used ->
        {:error, dgettext("engine", "%{who} ya ha usado Oleada de acción", who: who)}

      incompatible_spell?(spell_state(w, state), cost) ->
        {:error,
         dgettext(
           "engine",
           "un hechizo de acción adicional solo permite otros trucos de una acción en ese turno"
         )}

      match?({:spell, :long, _}, cost) ->
        {:error,
         dgettext(
           "engine",
           "este hechizo requiere más de una acción; no se resuelve instantáneamente en combate"
         )}

      true ->
        :ok
    end
  end

  def spend(w, who, {:delegated, cost}) do
    with :ok <- check(w, who, cost), do: {:ok, w}
  end

  def spend(w, who, cost) do
    with :ok <- check(w, who, cost) do
      if w.phase != :combat do
        {:ok, w}
      else
        w =
          if is_nil(w.turn_owner) and slot(cost) != "reaction",
            do: %{w | turn_owner: who},
            else: w

        state = Map.get(w.turn_state, who, %{})
        state = if slot(cost) != "reaction", do: Map.put(state, "round", w.round), else: state
        state = if slot(cost), do: Map.put(state, slot(cost), true), else: state
        state = if cost in [:attack, :surge], do: Map.put(state, "attacked", true), else: state

        state =
          if match?({:spell, _, _}, cost) and state["spell_turn"] != spell_turn(w),
            do: Map.drop(state, ["bonus_spell", "other_spell"]),
            else: state

        state =
          if match?({:spell, _, _}, cost),
            do: Map.put(state, "spell_turn", spell_turn(w)),
            else: state

        state =
          case cost do
            {:spell, :bonus, _} -> Map.put(state, "bonus_spell", true)
            {:spell, :action, 0} -> state
            {:spell, _, _} -> Map.put(state, "other_spell", true)
            _ -> state
          end

        owner = if slot(cost) != "reaction", do: w.turn_owner || who, else: w.turn_owner
        {:ok, %{w | turn_state: Map.put(w.turn_state, who, state), turn_owner: owner}}
      end
    end
  end

  def spell_cost(nil), do: :action

  def spell_cost(spell) do
    data = Enum.find(Dragonex.Heroes.SRDSpells.all(), &(&1.name == spell.name)) || %{}
    time = Map.get(data, :casting_time) || "1 action"

    kind =
      cond do
        String.contains?(time, "bonus") -> :bonus
        String.contains?(time, "reaction") -> :reaction
        time in ["1 action", "action"] -> :action
        true -> :long
      end

    {:spell, kind, spell.level}
  end

  defp incompatible_spell?(state, {:spell, :bonus, _}), do: state["other_spell"] == true
  defp incompatible_spell?(_state, {:spell, :action, 0}), do: false
  defp incompatible_spell?(state, {:spell, _, _}), do: state["bonus_spell"] == true
  defp incompatible_spell?(_, _), do: false

  defp spent(who, "action"),
    do: dgettext("engine", "%{who} ya ha gastado su acción este turno", who: who)

  defp spent(who, "bonus"),
    do: dgettext("engine", "%{who} ya ha gastado su acción adicional este turno", who: who)

  defp spent(who, "reaction"),
    do: dgettext("engine", "%{who} ya ha gastado su reacción este turno", who: who)

  defp spent(who, _death_save),
    do: dgettext("engine", "%{who} ya ha tirado su salvación contra muerte este turno", who: who)

  defp slot({:spell, kind, _}), do: slot(kind)
  defp slot(cost) when cost in [:action, :attack], do: "action"
  defp slot(cost) when cost in [:bonus, :flurry], do: "bonus"
  defp slot(:reaction), do: "reaction"
  defp slot(:death_save), do: "death_save"
  defp slot(_), do: nil

  def turn_id(w), do: "#{w.round}:#{w.turn_owner || w.current_combatant}"
  defp spell_turn(w), do: turn_id(w)
  defp spell_state(w, state), do: if(state["spell_turn"] == spell_turn(w), do: state, else: %{})

  def mark(w, who, key) do
    if w.phase == :combat do
      state = Map.get(w.turn_state, who, %{}) |> Map.put(key, true)
      %{w | turn_state: Map.put(w.turn_state, who, state)}
    else
      w
    end
  end

  def finish(w, nil), do: w

  def finish(w, who) do
    state = Map.get(w.turn_state, who, %{})
    if state["ended"] == true, do: w, else: do_finish(w, who, state)
  end

  defp do_finish(w, who, state) do
    c = World.character(w, who)

    w =
      if not is_nil(c) and c.raging and c.level < 15 and state["rage_attack"] != true and
           state["damaged"] != true do
        {:ok, next} = World.end_rage(who).(w)
        next
      else
        w
      end

    state = state |> Map.put("ended", true) |> Map.put("damaged", false)
    %{w | turn_state: Map.put(w.turn_state, who, state)}
  end
end
