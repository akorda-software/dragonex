defmodule Dragonex.TurnPolicy.WorldDriven do
  @moduledoc """
  A turn policy that reads the shared `Dragonex.World` to decide whose turn it is.

  The World is the single, impartial source of truth for the combat *order*
  (dice-rolled by `Dragonex.Actions.initiative/2`); this policy only *enforces*
  it. The DM (or any LLM) cannot skip, reorder or double-act — `can_act?/3`
  admits only the current participant.

  Sequencing:

    * **exploration** — round-robin over the participants (the DM narrates on its
      turn, same as everyone else).
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

  @doc """
  The combat turn cycle as Session participant ids: each name in
  `initiative_order` mapped to their controller (PCs → themselves, enemies →
  the DM). Consecutive DM slots are kept (D34: one beat per monster). Downed
  combatants are not filtered here — ending combat is the Game's job.
  """
  @spec combat_participants(World.t(), term()) :: [term()]
  def combat_participants(%World{phase: :combat, initiative_order: order, characters: chars}, dm)
      when is_list(order) do
    Enum.map(order, fn name ->
      case Map.get(chars, name) do
        %{side: "pc"} -> name
        _ -> dm
      end
    end)
  end

  def combat_participants(_, _), do: []

  defp pick(state, pool, phase) do
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
