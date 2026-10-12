defmodule Dragonex.TurnPolicy.WorldDriven do
  @moduledoc """
  A turn policy that reads the shared `Dragonex.World` to decide whose turn it is.

  The World is the single, impartial source of truth for the combat *order*
  (dice-rolled by `Dragonex.Actions.initiative/2`); this policy only *enforces*
  it. The DM (or any LLM) cannot skip, reorder or double-act — `can_act?/3`
  admits only the current participant.

  Sequencing:

    * **exploration** — round-robin over the participants (the DM narrates on its
      turn, same as everyone else), continuing after whoever holds the turn.
    * **combat** — cycle `world.initiative_order` one combatant at a time
      (D34). PCs map to themselves; each enemy maps to the DM (`:dm` option,
      default `"dm"`). Consecutive DM slots are **not** collapsed: three
      monsters in a row yield three DM beats.

  When the phase flips (exploration ⇄ combat), the cursor resets so the new
  phase starts cleanly at index 0.
  """

  @behaviour ExAgent.Session.TurnPolicy

  alias Dragonex.World

  defstruct ids: [],
            index: 0,
            current: nil,
            last_phase: nil,
            dm: "dm"

  @type t :: %__MODULE__{
          ids: [term()],
          index: non_neg_integer(),
          current: term() | nil,
          last_phase: :exploration | :combat | nil,
          dm: term()
        }

  @impl true
  def init(opts) do
    participants = Keyword.get(opts, :participants, [])

    %__MODULE__{
      ids: Enum.map(participants, & &1.id),
      dm: Keyword.get(opts, :dm, "dm")
    }
  end

  @impl true
  def next_participant(%__MODULE__{ids: []} = state, _ctx),
    do: {:done, %{state | current: nil}}

  def next_participant(%__MODULE__{} = state, ctx) do
    phase = world_phase(ctx)
    state = reset_on_phase_change(state, phase)

    case combat_order(state, ctx) do
      nil ->
        pick(state, state.ids, phase)

      order when order != [] ->
        pick(state, order, phase)

      _ ->
        pick(state, state.ids, phase)
    end
  end

  @impl true
  def can_act?(%__MODULE__{current: current}, id, _ctx),
    do: current != nil and current == id

  if {:handoff, 3} in ExAgent.Session.TurnPolicy.behaviour_info(:callbacks), do: @impl(true)
  def handoff(%__MODULE__{} = state, id, _ctx), do: {:ok, %{state | current: id}}

  @impl true
  def participant_joined(%__MODULE__{ids: ids} = state, %{id: id}),
    do: %{state | ids: ids ++ [id]}

  @impl true
  def participant_left(%__MODULE__{ids: ids, index: i} = state, id) do
    leaver_at = Enum.find_index(ids, &(&1 == id))
    new_ids = List.delete(ids, id)

    new_index =
      cond do
        is_nil(leaver_at) -> i
        leaver_at < i -> max(i - 1, 0)
        true -> i
      end

    current = if state.current == id, do: nil, else: state.current
    %{state | ids: new_ids, index: new_index, current: current}
  end

  # ----------------------------------------------------------- helpers

  @doc "Codec de política explícito para snapshots de Session en exAgent v2."
  if {:snapshot, 1} in ExAgent.Session.TurnPolicy.behaviour_info(:callbacks), do: @impl(true)

  def snapshot(%__MODULE__{} = state) do
    {:ok, 1,
     %{
       "ids" => state.ids,
       "index" => state.index,
       "current" => state.current,
       "last_phase" => if(state.last_phase, do: Atom.to_string(state.last_phase)),
       "dm" => state.dm
     }}
  end

  if {:restore_snapshot, 3} in ExAgent.Session.TurnPolicy.behaviour_info(:callbacks),
    do: @impl(true)

  def restore_snapshot(1, data, %{participants: participants}) when is_map(data) do
    ids = data["ids"]
    roster = Enum.map(participants, & &1.id)

    phase =
      case data["last_phase"] do
        "exploration" -> :exploration
        "combat" -> :combat
        nil -> nil
        _ -> :invalid
      end

    if is_list(ids) and Enum.all?(ids, &is_binary/1) and
         length(ids) == length(Enum.uniq(ids)) and MapSet.new(ids) == MapSet.new(roster) and
         is_integer(data["index"]) and data["index"] >= 0 and
         (is_nil(data["current"]) or data["current"] in ids) and
         data["dm"] in ids and phase != :invalid do
      {:ok,
       %__MODULE__{
         ids: ids,
         index: data["index"],
         current: data["current"],
         last_phase: phase,
         dm: data["dm"]
       }}
    else
      {:error, :invalid_policy_state}
    end
  end

  def restore_snapshot(_, _, _), do: {:error, :invalid_policy_state}

  @doc """
  The combat turn cycle as Session participant ids: each name in
  `initiative_order` mapped to their controller (PCs → themselves, enemies →
  the DM). Consecutive DM slots are kept (D34: one beat per monster). Downed
  combatants are not filtered here — ending combat is the Game's job.
  """
  @spec combat_participants(World.t(), term()) :: [term()]
  def combat_participants(%World{phase: :combat, initiative_order: order} = w, dm)
      when is_list(order) do
    order
    |> Enum.filter(&World.present?(w, &1))
    |> Enum.map(fn name ->
      case World.character(w, name) do
        %{side: "pc"} -> name
        _ -> dm
      end
    end)
  end

  def combat_participants(_, _), do: []

  # Exploration follows the participant who actually held the turn: a
  # TurnMaster handoff moves `current` without the cursor, and a stale cursor
  # could hand the DM a second consecutive beat. Combat keeps its cursor,
  # because consecutive DM slots repeat the same id (D34).
  defp pick(%__MODULE__{current: current} = state, pool, :exploration)
       when pool != [] and not is_nil(current) do
    case Enum.find_index(pool, &(&1 == current)) do
      nil ->
        cursor_pick(state, pool, :exploration)

      at ->
        next = rem(at + 1, length(pool))
        id = Enum.at(pool, next)
        {:ok, id, %{state | index: next + 1, current: id, last_phase: :exploration}}
    end
  end

  defp pick(state, pool, phase), do: cursor_pick(state, pool, phase)

  defp cursor_pick(state, pool, phase) do
    if pool == [] do
      {:done, %{state | current: nil, last_phase: phase}}
    else
      current = Enum.at(pool, rem(state.index, length(pool)))
      {:ok, current, %{state | index: state.index + 1, current: current, last_phase: phase}}
    end
  end

  defp world_phase(%{shared_state: %World{phase: p}}), do: p
  defp world_phase(_), do: :exploration

  defp reset_on_phase_change(%__MODULE__{last_phase: last} = state, phase)
       when last != phase,
       do: %{state | index: 0, last_phase: phase}

  defp reset_on_phase_change(state, _phase), do: state

  defp combat_order(%__MODULE__{dm: dm}, %{shared_state: %World{phase: :combat} = w}),
    do: combat_participants(w, dm)

  defp combat_order(_, _), do: nil
end
