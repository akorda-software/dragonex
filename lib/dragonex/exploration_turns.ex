defmodule Dragonex.ExplorationTurns do
  @moduledoc """
  Exploration fairness from actual turn markers, independent of narration.
  The DM may answer every PC, but those answers do not erase who last acted.
  Human autoplay counts as an AI companion; unavailable PCs cannot receive
  the word. This module reads data only and never changes World or Session.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.World

  def context(%World{phase: :exploration} = world, participants, pc_agents, events) do
    manual =
      participants
      |> Enum.filter(fn {name, participant} ->
        participant.kind == :human and not Map.has_key?(pc_agents, name)
      end)
      |> Enum.map(&elem(&1, 0))

    recent =
      events
      |> Enum.reverse()
      |> Enum.filter(&match?(%{type: :turn}, &1))
      |> Enum.take_while(&(field(&1.payload, :phase) in [nil, :exploration, "exploration"]))
      |> Enum.filter(&main_turn?/1)
      |> Enum.map(& &1.actor)
      |> Enum.filter(&Map.has_key?(participants, &1))
      |> Enum.reject(&(&1 == "dm"))

    humans =
      manual
      |> Enum.filter(&eligible?(world, &1))
      |> Enum.sort_by(fn name ->
        case Enum.find_index(recent, &(&1 == name)) do
          nil -> {0, 0, name}
          index -> {1, -index, name}
        end
      end)

    ai =
      pc_agents
      |> Map.keys()
      |> Enum.filter(&(Map.has_key?(participants, &1) and eligible?(world, &1)))
      |> Enum.sort()

    acted =
      recent
      |> Enum.take_while(&(&1 not in manual))
      |> Enum.filter(&(&1 in ai))
      |> Enum.reverse()
      |> Enum.uniq()

    opening? =
      not Enum.any?(events, fn event ->
        match?(%{type: :turn}, event) and Map.has_key?(participants, event.actor) and
          match?(%{side: "pc"}, World.character(world, event.actor))
      end)

    %{humans: humans, ai: ai, ai_acted: acted, opening?: opening?}
  end

  def context(_, _, _, _), do: nil

  @doc "After presenting a new mixed party's scene, let a manual player decide first."
  def opening_human(%{opening?: true, humans: [name | _], ai: [_ | _]}), do: name
  def opening_human(_), do: nil

  def human_due(%{humans: [name | _], ai: [_ | _] = ai, ai_acted: acted}) do
    if Enum.all?(ai, &(&1 in acted)), do: name
  end

  def human_due(_), do: nil

  def human_after_repeat(%{humans: [name | _]}, "dm"), do: name

  def human_after_repeat(%{humans: [name | _], ai_acted: acted}, target) do
    if target in acted, do: name
  end

  def human_after_repeat(_, _), do: nil

  def human_after_ai(%{humans: [name | _], ai_acted: [_ | _]}), do: name
  def human_after_ai(_), do: nil

  def brief(%{humans: [_ | _] = humans, ai: [_ | _], ai_acted: acted}) do
    already = if acted == [], do: dgettext("prompts", "nadie"), else: Enum.join(acted, ", ")

    dgettext(
      "prompts",
      "Personas que juegan: %{humans}.\n" <>
        "Compañeros que ya actuaron desde la última intervención humana: %{already}.\n" <>
        "No repitas a esos compañeros antes de devolver la palabra a una persona. " <>
        "Puedes dar una intervención a otro compañero disponible; el DM responde entre ellas.",
      humans: Enum.join(humans, ", "),
      already: already
    )
  end

  def brief(_), do: ""

  defp eligible?(world, name) do
    match?(%{side: "pc"}, World.character(world, name)) and
      World.validate_actor(world, name) == :ok
  end

  defp main_turn?(%{type: :turn, payload: payload}) do
    field(payload, :kind) in [nil, :start, "start"] and
      field(payload, :turn_kind) not in [:reaction, "reaction"]
  end

  defp main_turn?(_), do: false

  defp field(payload, key), do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
end
