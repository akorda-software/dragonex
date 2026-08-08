defmodule Dragones.Brief do
  @moduledoc """
  A compact, LLM-readable snapshot of the world: phase, round, scene, initiative,
  whose turn it is, and one line per character.

  This is the per-turn context every agent (DM and AI PCs) "sees" to decide its
  action. It used to live in `Dragones.DM`, but the PC agents consume the same
  snapshot (the Game builds one `turn_prompt/5` for whoever's turn it is), so it
  belongs in a neutral home rather than under the DM's name.
  """

  alias Dragones.{Character, World}

  @doc """
  Build the world brief string.

  `current` is the participant whose turn it is; `dm` is the DM participant id.
  When it's the DM's turn, the header lists the monsters it controls (since the
  policy folds all enemies onto the DM's single turn). `kinds` maps participant
  name → `:ai` | `:human`.
  """
  @spec world_brief(World.t(), String.t() | nil, String.t(), %{optional(String.t()) => atom()}) ::
          String.t()
  def world_brief(%World{} = w, current, dm \\ "dm", kinds \\ %{}) do
    phase_line =
      case w do
        %World{phase: :combat, round: round, initiative_order: order} when order != [] ->
          "Combate -- ronda #{round} (iniciativa: #{Enum.join(order, " -> ")})"

        %World{phase: :combat} ->
          "Combate -- ronda #{w.round}"

        _ ->
          "Exploración"
      end

    turn_line = turn_for(w, current, dm, kinds)
    control_line = control_line(w, kinds)
    facts_line = facts_line(w)

    chars =
      w.characters
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} -> describe_char(name, c, current, dm, w.spell_slots, kinds) end)
      |> Enum.join("\n")

    [phase_line, turn_line, control_line, facts_line, "Escena: #{w.scene}", chars]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc "Build the per-turn user message: world snapshot + a directing instruction."
  @spec turn_prompt(
          World.t(),
          String.t() | nil,
          String.t(),
          String.t(),
          %{optional(String.t()) => atom()}
        ) :: String.t()
  def turn_prompt(%World{} = w, current, instruction, dm \\ "dm", kinds \\ %{}) do
    "WORLD:\n#{world_brief(w, current, dm, kinds)}\n\n#{instruction}"
  end

  # Durable narrative facts the DM has established. Surfaced every turn so the
  # partida's concrete state survives history truncation and every agent reads
  # the same ground truth — keeping hooks from being dropped or re-introduced.
  defp facts_line(%World{facts: []}), do: ""

  defp facts_line(%World{facts: facts}) do
    body = Enum.map_join(facts, "\n", &"- #{&1}")

    "Hechos establecidos (verdad canónica de la partida — confía en esto, no lo contradigas ni lo reintroduzcas):\n" <>
      body
  end

  # Tell the DM who auto-acts (AI PCs) vs who waits for a human, so it doesn't
  # ask a human player to act for a bot, or vice versa.
  defp control_line(%World{characters: chars}, kinds) do
    pcs = chars |> Map.values() |> Enum.filter(&(&1.side == "pc")) |> Enum.map(& &1.name)
    {ai, humans} = Enum.split_with(pcs, fn n -> kinds[n] == :ai end)

    case {ai, humans} do
      {[], []} ->
        ""

      {[], _} ->
        "Control: #{Enum.join(humans, ", ")} son jugadores humanos (esperan su input)."

      {_, []} ->
        "Control: #{Enum.join(ai, ", ")} son PJ gestionados por IA (juegan solos en su turno; NO les pidas su acción)."

      {_, _} ->
        "Control: #{Enum.join(humans, ", ")} son jugadores humanos (esperan su input); " <>
          "#{Enum.join(ai, ", ")} son PJ gestionados por IA (juegan solos; NO les pidas su acción)."
    end
  end

  defp turn_for(_w, nil, _dm, _kinds), do: ""

  defp turn_for(%World{characters: chars}, current, dm, _kinds) when current == dm do
    monsters =
      chars
      |> Enum.filter(fn {_, c} -> c.side != "pc" and c.hp > 0 end)
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.sort()

    if monsters == [],
      do: "Es TU turno (DM).",
      else: "Es TU turno (DM) -- actúa por: #{Enum.join(monsters, ", ")}."
  end

  defp turn_for(_w, current, _dm, kinds) do
    role = if kinds[current] == :ai, do: "IA, auto-juega", else: "jugador humano"
    "Es el turno de #{current} (#{role}) -- solo #{current} puede actuar ahora."
  end

  defp describe_char(name, %Character{} = c, current, dm, spell_slots, kinds) do
    fails = c.death_saves[:fails] || 0

    status =
      cond do
        (c.hp || 0) <= 0 and c.max_hp not in [nil, 0] and fails >= 3 -> " [MUERTO]"
        (c.hp || 0) <= 0 and c.max_hp not in [nil, 0] -> " [CAÍDO]"
        true -> ""
      end

    ai_tag = if kinds[name] == :ai, do: " IA", else: ""

    cond_str =
      case c.conditions || [] do
        [] ->
          ""

        conds ->
          names =
            Enum.map(conds, fn
              %{condition: cd} -> cd
              %{"condition" => cd} -> cd
              cd when is_binary(cd) -> cd
              _ -> nil
            end)
            |> Enum.reject(&is_nil/1)

          if names == [], do: "", else: " [#{Enum.join(names, ", ")}]"
      end

    you = if name == current and current != dm, do: "  <- ACTÚA AHORA", else: ""
    weapons = c.weapons |> Enum.map(& &1.name) |> Enum.join(", ")
    spells = if c.spells == [], do: [], else: c.spells |> Enum.map(& &1.name) |> Enum.join(", ")

    level_tag = if c.level > 1, do: " N#{c.level}", else: ""

    gear = ["Armas: #{weapons}"] ++ if spells == [], do: [], else: ["Hechizos: #{spells}"]

    # Spell slots: only show for tracked casters
    slot_str = slot_summary(spell_slots, name)

    gear = if slot_str != "", do: gear ++ [slot_str], else: gear

    "- #{name} (#{c.class}#{level_tag}, #{c.side}#{ai_tag}): #{c.hp}/#{c.max_hp} pg, CA #{c.ac}#{status}#{cond_str}#{you} -- #{Enum.join(gear, "; ")}"
  end

  defp slot_summary(slots, name) when is_map(slots) and is_map_key(slots, name) do
    char_slots = Map.get(slots, name, %{})

    if char_slots == %{} do
      ""
    else
      parts =
        char_slots
        |> Enum.sort_by(fn {level, _} -> level end)
        |> Enum.map(fn {level, count} -> "N#{level}:#{count}" end)
        |> Enum.join(", ")

      "Casillas: #{parts}"
    end
  end

  defp slot_summary(_, _), do: ""
end
