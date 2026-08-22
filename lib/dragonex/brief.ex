defmodule Dragonex.Brief do
  @moduledoc """
  A compact, LLM-readable snapshot of the world: phase, round, scene, initiative,
  whose turn it is, and one line per character.

  This is the per-turn context every agent (DM and AI PCs) "sees" to decide its
  action. It used to live in `Dragonex.DM`, but the PC agents consume the same
  snapshot (the Game builds one `turn_prompt/5` for whoever's turn it is), so it
  belongs in a neutral home rather than under the DM's name.
  """

  alias Dragonex.{Character, World}

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
    acted_line = acted_this_round_line(w)

    chars =
      w.characters
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} -> describe_char(name, c, current, dm, w.spell_slots, kinds) end)
      |> Enum.join("\n")

    [phase_line, turn_line, control_line, acted_line, facts_line, "Escena: #{w.scene}", chars]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Compact brief for the TurnMaster beat (D25): initiative, who already acted
  this round, living/down, and who holds the word now.
  """
  @spec turnmaster_brief(World.t(), String.t() | nil, [String.t()], map()) :: String.t()
  def turnmaster_brief(%World{} = w, last_actor, participants \\ [], intents \\ %{}) do
    phase =
      case w.phase do
        :combat ->
          order = Enum.join(w.initiative_order || [], " -> ")
          "Combate ronda #{w.round}. Iniciativa: #{order}."

        _ ->
          "Exploración."
      end

    last = if last_actor, do: "Acaba de actuar: #{last_actor}.", else: "Arranque."
    acted = acted_this_round_line(w)

    roster =
      if participants == [], do: "", else: "Participantes: #{Enum.join(participants, ", ")}."

    living =
      w.characters
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.map_join("\n", fn {name, c} ->
        status =
          cond do
            World.dead?(w, name) -> "MUERTO"
            World.down?(w, name) -> "caído"
            true -> "vivo #{c.hp}/#{c.max_hp}"
          end

        "- #{name} (#{c.side}): #{status}"
      end)

    [
      phase,
      last,
      acted,
      roster,
      human_intents_block(intents),
      "Estado:",
      living,
      "Escena: #{w.scene}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @intent_preview 200

  defp human_intents_block(intents) when intents == %{}, do: ""
  defp human_intents_block(intents) when not is_map(intents), do: ""

  defp human_intents_block(intents) do
    lines =
      intents
      |> Enum.sort_by(fn {name, _} -> to_string(name) end)
      |> Enum.map(&intent_line/1)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> ""
      list -> "Intenciones humanas pendientes:\n" <> Enum.join(list, "\n")
    end
  end

  defp intent_line({name, raw}) do
    cleaned =
      raw
      |> Dragonex.Intents.text()
      |> Dragonex.Text.scrub()
      |> trim_preview()

    if cleaned == "", do: nil, else: "- #{name}: «#{cleaned}»"
  end

  defp trim_preview(text) do
    if String.length(text) <= @intent_preview,
      do: text,
      else: String.slice(text, 0, @intent_preview) <> "…"
  end

  defp acted_this_round_line(%World{phase: :combat, acted_this_round: %MapSet{} = acted}) do
    case MapSet.to_list(acted) do
      [] -> "acted_this_round: (nadie)"
      names -> "acted_this_round: #{Enum.join(Enum.sort(names), ", ")}"
    end
  end

  defp acted_this_round_line(%World{phase: :combat, acted_this_round: list}) when is_list(list) do
    acted_this_round_line(%World{phase: :combat, acted_this_round: MapSet.new(list)})
  end

  defp acted_this_round_line(_), do: ""

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
      case Character.condition_names(c) do
        [] -> ""
        names -> " [#{Enum.join(names, ", ")}]"
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
