defmodule Dragonex.Brief do
  @moduledoc """
  A compact, LLM-readable snapshot of the world: phase, round, scene, initiative,
  whose turn it is, and one line per character.

  This is the per-turn context every agent (DM and AI PCs) "sees" to decide its
  action. It used to live in `Dragonex.DM`, but the PC agents consume the same
  snapshot (the Game builds one `turn_prompt/5` for whoever's turn it is), so it
  belongs in a neutral home rather than under the DM's name.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Character, ClassResources, NPCStatement, Rest, World}
  alias Dragonex.Heroes.Translations
  alias Dragonex.I18n
  alias Dragonex.Rules.Effects

  @doc """
  Build the world brief string.

  `current` is the participant whose turn it is; `dm` is the DM participant id.
   When it's the DM's turn, the header lists the combatant whose slot it is
   (`world.current_combatant`, D34) or every living monster if unset. `kinds`
   maps participant name → `:ai` | `:human`.
  """
  @spec world_brief(World.t(), String.t() | nil, String.t(), %{optional(String.t()) => atom()}) ::
          String.t()
  def world_brief(%World{} = w, current, dm \\ "dm", kinds \\ %{}) do
    phase_line =
      case w do
        %World{phase: :combat, round: round, initiative_order: order} when order != [] ->
          dgettext("prompts", "Combate -- ronda %{round} (iniciativa: %{order})",
            round: round,
            order: Enum.join(order, " -> ")
          )

        %World{phase: :combat} ->
          dgettext("prompts", "Combate -- ronda %{round}", round: w.round)

        _ ->
          dgettext("prompts", "Exploración")
      end

    turn_line = turn_for(w, current, dm, kinds)
    control_line = control_line(w, kinds)
    facts_line = facts_line(w)
    acted_line = acted_this_round_line(w)

    chars =
      World.present_characters(w)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} -> describe_char(name, c, current, dm, w, kinds) end)
      |> Enum.join("\n")

    [
      phase_line,
      turn_line,
      control_line,
      acted_line,
      clock_line(w),
      scene_line(w),
      facts_line,
      absence_line(w),
      Dragonex.Conversation.brief(w),
      chars,
      clock_update_instruction(w, current, dm),
      scene_update_instruction(current, dm)
    ]
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

          dgettext("prompts", "Combate ronda %{round}. Iniciativa: %{order}.",
            round: w.round,
            order: order
          )

        _ ->
          dgettext("prompts", "Exploración.")
      end

    last =
      if last_actor,
        do: dgettext("prompts", "Acaba de actuar: %{actor}.", actor: last_actor),
        else: dgettext("prompts", "Arranque.")

    acted = acted_this_round_line(w)

    roster =
      if participants == [],
        do: "",
        else:
          dgettext("prompts", "Participantes: %{names}.", names: Enum.join(participants, ", "))

    living =
      World.present_characters(w)
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.map_join("\n", fn {name, c} ->
        "- #{name} (#{identity(c)}, #{c.side}): #{state_prefix(w, name, c)}#{hp_clause(c)}, #{ac_clause(c)}"
      end)

    [
      phase,
      last,
      acted,
      roster,
      human_intents_block(intents),
      absence_line(w),
      Dragonex.Conversation.brief(w),
      clock_line(w),
      scene_line(w),
      facts_line(w),
      dgettext("prompts", "Estado:"),
      living
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @intent_preview 200

  defp absence_line(w) do
    absent = Map.get(w, :absent_characters, %{})

    if absent == %{} do
      ""
    else
      dgettext(
        "prompts",
        "Fuera de escena: no son objetivos ni combatientes presentes; usa return_to_scene para volver con su ficha conservada."
      ) <>
        "\n" <>
        (absent
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join("\n", fn {name, reason} -> "#{name}: #{reason}" end))
    end
  end

  defp human_intents_block(intents) when intents == %{}, do: ""
  defp human_intents_block(intents) when not is_map(intents), do: ""

  defp human_intents_block(intents) do
    lines =
      intents
      |> Enum.sort_by(fn {name, _} -> to_string(name) end)
      |> Enum.map(&intent_line/1)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] ->
        ""

      list ->
        dgettext("prompts", "Intenciones humanas pendientes:") <> "\n" <> Enum.join(list, "\n")
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
      [] -> "acted_this_round: " <> dgettext("prompts", "(nadie)")
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

  defp clock_line(w),
    do:
      dgettext(
        "prompts",
        "Tiempo del mundo: %{seconds} s transcurridos (reloj relativo, no hora del día).",
        seconds: w.elapsed_seconds
      )

  defp clock_update_instruction(%World{phase: :exploration}, current, dm) when current == dm do
    dgettext(
      "prompts",
      "RELOJ EN EXPLORACIÓN: si resuelves un viaje o una espera ya declarados con duración explícita, " <>
        "registra el tiempo realmente transcurrido con advance_time(segundos) UNA VEZ antes de narrar la llegada. " <>
        "Cambiar el lugar con set_scene no avanza el reloj ni caduca los efectos. " <>
        "Los segundos deben corresponder a la duración declarada; el motor aplica el reloj y las caducidades. " <>
        "Una pregunta, propuesta pendiente o indicación de cuánto tarda un camino NO consume tiempo: " <>
        "no inventes un viaje ni una duración. Consulta el resultado y el reloj vigente; " <>
        "no repitas tiempo ya aplicado. short_rest, long_rest y rest_party ya avanzan su propia duración."
    )
  end

  defp clock_update_instruction(_, _, _), do: ""

  defp scene_line(w) do
    dgettext("prompts", "Escena registrada: %{scene}", scene: w.scene) <>
      "\n" <>
      dgettext(
        "prompts",
        "Es la última descripción guardada: prevalecen los hechos canónicos y el estado actual, " <>
          "junto con las decisiones posteriores del historial. No reintroduzcas un encargo ya cerrado."
      )
  end

  defp scene_update_instruction(current, dm) when current == dm do
    dgettext(
      "prompts",
      "Si la descripción registrada quedó antigua tras un cambio acordado, actualízala con set_scene: " <>
        "solo el entorno vigente, sin mover ni hacer actuar a los PCs."
    )
  end

  defp scene_update_instruction(_, _), do: ""

  # Project the existing strings without changing their stored meaning or clock.
  # An attributed claim must not inherit the confirmed-facts heading (D198).
  defp facts_line(%World{facts: []}), do: ""

  defp facts_line(%World{facts: facts}) do
    {testimony, confirmed} = Enum.split_with(facts, &NPCStatement.attributed?/1)

    [confirmed_facts(confirmed), attributed_testimony(testimony)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp confirmed_facts([]), do: ""

  defp confirmed_facts(facts),
    do:
      dgettext(
        "prompts",
        "Hechos establecidos (confirmados en la partida; no los contradigas ni los reintroduzcas):"
      ) <>
        "\n" <>
        Enum.map_join(facts, "\n", &"- #{&1}")

  defp attributed_testimony([]), do: ""

  defp attributed_testimony(facts) do
    positions =
      facts
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {fact, index}, acc ->
        Map.update(acc, testimony_source(fact), {1, index}, fn {count, _} ->
          {count + 1, index}
        end)
      end)

    entries =
      facts
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {fact, index} ->
        {count, last} = Map.fetch!(positions, testimony_source(fact))

        if count > 1 and index == last,
          do:
            dgettext(
              "prompts",
              "Última entrada conservada de esta fuente (no confirma su contenido):"
            ) <> "\n- #{fact}",
          else: "- #{fact}"
      end)

    dgettext("prompts", "Testimonios atribuidos (contenido sin confirmar):") <>
      "\n" <>
      dgettext(
        "prompts",
        "Los testimonios atribuidos registran lo que alguien afirma; no confirman por sí solos su contenido. Conserva la fuente y sus dudas."
      ) <>
      "\n" <>
      dgettext(
        "prompts",
        "Las entradas siguen el orden conservado al registrarlas. Ese orden no determina cuándo ocurrió lo relatado; " <>
          "la última entrada de una fuente no confirma su contenido ni sustituye automáticamente las anteriores."
      ) <>
      "\n" <>
      dgettext(
        "prompts",
        "En los testimonios con marca temporal, «ayer», «hace dos días» o «mañana» se refieren al reloj del registro, no al reloj actual. " <>
          "En los testimonios antiguos sin marca temporal, no infieras cuándo se recogieron. El reloj es relativo, no una fecha u hora del día."
      ) <>
      "\n" <>
      entries
  end

  # Group only the complete written source; do not infer aliases or merge roles.
  # The raw fact and its place in the retained list remain unchanged.
  defp testimony_source(fact) do
    fact
    |> NPCStatement.speaker()
    |> String.normalize(:nfc)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
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
        dgettext("prompts", "Control: %{humans} son jugadores humanos (esperan su input).",
          humans: Enum.join(humans, ", ")
        )

      {_, []} ->
        dgettext(
          "prompts",
          "Control: %{ai} son PJ gestionados por IA (juegan solos en su turno; NO les pidas su acción).",
          ai: Enum.join(ai, ", ")
        )

      {_, _} ->
        dgettext(
          "prompts",
          "Control: %{humans} son jugadores humanos (esperan su input); " <>
            "%{ai} son PJ gestionados por IA (juegan solos; NO les pidas su acción).",
          humans: Enum.join(humans, ", "),
          ai: Enum.join(ai, ", ")
        )
    end
  end

  defp turn_for(_w, nil, _dm, _kinds), do: ""

  defp turn_for(%World{current_combatant: slot}, current, dm, _kinds)
       when current == dm and is_binary(slot) and slot != "" do
    dgettext("prompts", "Es TU turno (DM) -- actúa por: %{actors}.", actors: slot)
  end

  defp turn_for(%World{} = w, current, dm, _kinds) when current == dm do
    monsters =
      World.present_characters(w)
      |> Enum.filter(fn {_, c} -> c.side != "pc" and c.hp > 0 end)
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.sort()

    if monsters == [],
      do: dgettext("prompts", "Es TU turno (DM)."),
      else:
        dgettext("prompts", "Es TU turno (DM) -- actúa por: %{actors}.",
          actors: Enum.join(monsters, ", ")
        )
  end

  defp turn_for(_w, current, _dm, kinds) do
    role =
      if kinds[current] == :ai,
        do: dgettext("prompts", "IA, auto-juega"),
        else: dgettext("prompts", "jugador humano")

    dgettext("prompts", "Es el turno de %{actor} (%{role}) -- solo %{actor} puede actuar ahora.",
      actor: current,
      role: role
    )
  end

  defp describe_char(name, %Character{} = c, current, dm, %World{} = w, kinds) do
    ai_tag = if kinds[name] == :ai, do: " " <> dgettext("prompts", "IA"), else: ""

    "- #{name} (#{identity(c)}, #{c.side}#{ai_tag}): #{hp_clause(c)}, #{ac_clause(c)}#{vitality_tag(w, name, c)}#{condition_tag(c)}#{acting_mark(name, current, dm, w)} -- #{Enum.join(gear_bits(c, w, name), "; ")}"
  end

  defp identity(%Character{} = c) do
    dgettext("prompts", "raza %{race}, clase %{class}, nivel %{level}",
      race: label(:race, c.race),
      class: label(:class, c.class),
      level: level_token(c.level)
    )
  end

  defp label(_kind, value) when value in [nil, ""], do: "—"

  defp label(kind, value) when is_binary(value) do
    shown = display(kind, value)

    if same_label?(shown, value), do: value, else: "#{value}/#{shown}"
  end

  defp label(_, _), do: "—"

  defp display(:race, value), do: Translations.race_display(value, I18n.locale())
  defp display(:class, value), do: Translations.class(value, I18n.locale())

  defp same_label?(shown, value) do
    not is_binary(shown) or shown == "" or String.downcase(shown) == String.downcase(value)
  end

  defp level_token(level) when is_integer(level), do: Integer.to_string(level)
  defp level_token(_), do: "?"

  defp hp_clause(%Character{} = c) do
    base = dgettext("prompts", "%{hp}/%{max_hp} pg", hp: c.hp || 0, max_hp: c.max_hp || 0)
    temp = c.temp_hp || 0

    if is_integer(temp) and temp > 0,
      do: base <> ", " <> dgettext("prompts", "%{temp} temporales", temp: temp),
      else: base
  end

  defp ac_clause(%Character{ac: ac} = c) when is_integer(ac) do
    effective = Effects.effective_ac(c)

    if effective == ac,
      do: dgettext("prompts", "CA %{ac}", ac: effective),
      else: dgettext("prompts", "CA %{ac} (base %{base})", ac: effective, base: ac)
  end

  defp ac_clause(_), do: dgettext("prompts", "CA %{ac}", ac: "?")

  defp vitality_tag(%World{} = w, name, %Character{} = c) do
    cond do
      World.dead?(w, name) -> " " <> dgettext("prompts", "[MUERTO]")
      engine_stable?(c) -> " " <> dgettext("prompts", "[ESTABLE]")
      (c.hp || 0) <= 0 and c.max_hp not in [nil, 0] -> " " <> dgettext("prompts", "[CAÍDO]")
      true -> ""
    end
  end

  defp engine_stable?(%Character{hp: hp, death_saves: %{successes: successes, fails: fails}})
       when is_integer(hp) and hp <= 0 and is_integer(successes) and is_integer(fails) and
              successes >= 3 and fails < 3,
       do: true

  defp engine_stable?(_), do: false

  defp state_prefix(%World{} = w, name, %Character{} = c) do
    case vitality_tag(w, name, c) do
      "" -> if (c.hp || 0) > 0, do: dgettext("prompts", "vivo") <> " ", else: ""
      tag -> tag <> " "
    end
  end

  defp condition_tag(c) do
    case Character.condition_names(c) do
      [] -> ""
      names -> " [#{Enum.join(names, ", ")}]"
    end
  end

  defp acting_mark(name, current, dm, %World{} = w) do
    cond do
      is_binary(w.current_combatant) and name == w.current_combatant -> acting_now()
      name == current and current != dm -> acting_now()
      true -> ""
    end
  end

  defp acting_now, do: "  <- " <> dgettext("prompts", "ACTÚA AHORA")

  defp gear_bits(%Character{} = c, %World{} = w, name) do
    weapons = c.weapons |> List.wrap() |> Enum.map(&gear_name/1) |> Enum.reject(&is_nil/1)
    spells = c.spells |> List.wrap() |> Enum.map(&gear_name/1) |> Enum.reject(&is_nil/1)
    gear = [dgettext("prompts", "Armas: %{weapons}", weapons: Enum.join(weapons, ", "))]

    gear =
      if spells == [],
        do: gear,
        else:
          gear ++ [dgettext("prompts", "Hechizos: %{spells}", spells: Enum.join(spells, ", "))]

    gear = if c.side == "pc", do: gear ++ [inventory_summary(c.inventory)], else: gear
    slot_str = slot_summary(w.spell_slots, name)
    gear = if slot_str != "", do: gear ++ [slot_str], else: gear
    gear ++ resource_bits(c, w, name)
  end

  defp inventory_summary(items) do
    case List.wrap(items) do
      [] ->
        dgettext("prompts", "Inventario: vacío")

      items ->
        dgettext("prompts", "Inventario: %{items}",
          items: Enum.map_join(items, "; ", &"#{&1.name} ×#{&1.qty}")
        )
    end
  end

  defp resource_bits(%Character{} = c, w, name) do
    pools = Enum.map(ClassResources.pools(c), &"#{&1.label}: #{&1.remaining}/#{&1.capacity}")

    recoveries =
      for {class, minimum, field, label} <- [
            {"fighter", 1, :second_wind_used, dgettext("prompts", "Segundo aliento")},
            {"fighter", 2, :action_surge_used, dgettext("prompts", "Oleada de acción")},
            {"wizard", 1, :arcane_recovery_used, dgettext("prompts", "Recuperación arcana")},
            {"cleric", 2, :channel_divinity_used, dgettext("prompts", "Canalizar divinidad")}
          ],
          c.class == class and (c.level || 1) >= minimum do
        status =
          if Map.get(c, field) == true,
            do: dgettext("prompts", "gastado"),
            else: dgettext("prompts", "disponible")

        "#{label}: #{status}"
      end

    dice =
      if c.side == "pc",
        do: [
          dgettext("prompts", "Dados de golpe: %{remaining}/%{level} d%{die}",
            remaining: Rest.remaining(w, name),
            level: c.level,
            die: World.hit_die_size(c.class)
          )
        ],
        else: []

    rest = if c.side == "pc", do: [long_rest_status(w, name)], else: []
    pools ++ recoveries ++ dice ++ rest ++ shape_bits(c)
  end

  defp long_rest_status(w, name) do
    cond do
      World.validate_actor(w, name) != :ok or w.phase == :combat ->
        dgettext("prompts", "Descanso largo: bloqueado")

      Rest.long_rest_wait(w, name) > 0 ->
        dgettext("prompts", "Descanso largo: beneficio disponible en %{seconds} s",
          seconds: Rest.long_rest_wait(w, name)
        )

      true ->
        dgettext("prompts", "Descanso largo: disponible fuera de combate")
    end
  end

  defp shape_bits(%Character{wild_shape: %{} = shape}) do
    beast = Map.get(shape, :beast) || Map.get(shape, "beast") || dgettext("prompts", "bestia")
    [dgettext("prompts", "Forma actual: %{beast} (no puede conjurar)", beast: beast)]
  end

  defp shape_bits(_), do: []

  defp gear_name(%{name: name}) when is_binary(name), do: name
  defp gear_name(%{"name" => name}) when is_binary(name), do: name
  defp gear_name(_), do: nil

  defp slot_summary(slots, name) when is_map(slots) and is_map_key(slots, name) do
    char_slots = Map.get(slots, name, %{})

    if char_slots == %{} do
      ""
    else
      parts =
        char_slots
        |> Enum.sort_by(fn {level, _} -> level end)
        |> Enum.map(fn {level, count} ->
          dgettext("prompts", "N%{level}:%{count}", level: level, count: count)
        end)
        |> Enum.join(", ")

      dgettext("prompts", "Casillas: %{slots}", slots: parts)
    end
  end

  defp slot_summary(_, _), do: ""
end
