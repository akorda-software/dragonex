defmodule Dragonex.TurnMaster.Decision do
  @moduledoc """
  Per-beat recorder for the TurnMaster's handoff decision.

  Mirrors `Dragonex.RollLog`: tools run in ExAgent worker tasks (not the beat
  Task), so a process dictionary is useless. A short-lived `Agent` addressed by
  pid lets every tool write the decision and the beat Task read it when the
  model finishes.

  The TurnMaster **never mutates the World** (D6 / D25). Tools only call
  `record/2`; the `Game` reads `get/1` and applies `Session.handoff/2` or
  `Session.update_state/3`.
  """

  @type action :: :give_turn_to | :cut_in | :react | :pass_to_dm | :end_scene

  @type t :: %{
          action: action(),
          to: String.t() | nil
        }

  @doc "Start a per-beat decision recorder (linked to the caller)."
  @spec start() :: Agent.on_start()
  def start, do: Agent.start_link(fn -> nil end)

  @doc "Record the decision. Last write wins (one tool-call per beat by contract)."
  @spec record(pid(), t()) :: :ok
  def record(recorder, %{action: action} = decision) when is_atom(action) do
    Agent.update(recorder, fn _ -> decision end)
  end

  @doc "The decision recorded this beat, or `nil` if the model never called a tool."
  @spec get(pid()) :: t() | nil
  def get(recorder), do: Agent.get(recorder, & &1)

  @doc "Stop the recorder."
  @spec stop(pid()) :: :ok
  def stop(recorder), do: Agent.stop(recorder)
end
