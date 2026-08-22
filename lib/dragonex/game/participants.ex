defmodule Dragonex.Game.Participants do
  @moduledoc """
  Roster predicates over the Game state: who is human, who is AI-driven, who
  holds a character sheet. Pure lookups — no Session/World mutation.

  Extracted from `Dragonex.Game` so both the loop and the TurnMaster
  orchestration share one definition of "human" vs "AI PC".
  """

  alias ExAgent.Session

  def human?(%{participants: ps}, name) do
    case Map.get(ps, name) do
      %{kind: :human} -> true
      _ -> false
    end
  end

  # An AI-controlled participant: either an original AI PC or a human with
  # auto-play enabled (has an entry in pc_agents).
  def ai_pc?(%{pc_agents: agents}, name) do
    name != "dm" and Map.has_key?(agents, name)
  end

  def pc_actor?(_state, name) when name in [nil, "", "dm"], do: false
  def pc_actor?(state, name), do: human?(state, name) or ai_pc?(state, name)

  # The subset of pc_agents that are auto-played HUMANS (not original AI PCs).
  # This is what the LiveView toggle reflects, so it survives reloads and stays
  # consistent across viewers.
  def auto_humans(%{pc_agents: agents} = state) do
    agents
    |> Map.keys()
    |> Enum.filter(&human?(state, &1))
    |> MapSet.new()
  end

  def world_character(%{session: session}, name) do
    world = Session.read_state(session)
    Map.get(world.characters, name)
  end

  def pc_names(%{characters: chars}) do
    chars
    |> Enum.filter(fn {_, c} -> c.side == "pc" end)
    |> Enum.map(&elem(&1, 0))
  end
end
