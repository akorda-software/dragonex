defmodule Dragones.DM do
  @moduledoc """
  The Dungeon Master agent: a strict system prompt, the bridge tool set, and a
  concise world snapshot the LLM receives each turn.

  The DM narrates, voices monsters/NPCs and referees — but it NEVER resolves an
  outcome. Every roll, attack, save and death save goes through the tools; the
  DM only reads their textual results and weaves them into the scene.
  """

  alias Dragones.{Character, Tools, World}
  alias ExAgent.{Compaction, Message, Message.Response}

  @doc """
  The DM's tool set (it referees + controls monsters + narrates).

  The rules-resolution tools (`make_attack`, `cast_spell`, …) get a larger retry
  budget: if the DM proposes as the wrong participant, the control guard returns
  a *directive* error telling it exactly who must act, and the extra retries give
  it room to self-correct instead of failing the beat.
  """
  @spec tools() :: [term()]
  def tools do
    resolution = ~w(make_attack cast_spell ability_check make_death_save heal roll_initiative)a

    Enum.map(Tools.tools(), fn tool ->
      if tool.name in resolution, do: %{tool | max_retries: 3}, else: tool
    end)
  end

  @doc """
  Build the DM agent.

  Options:

    * `:story_bible`     — the campaign's stable context (hooks, NPCs, tone). It
      is baked into the **system instructions** (a stable prefix) so the
      provider can cache it across turns rather than re-sending it each beat.
    * `:summarizer`      — a *cheap* model used by compaction to recap old
      history. When present, a `Compaction.Summary` capability is wired in.
    * `:max_tokens`      — output cap per beat (default 512).
    * `:compaction_*`    — `:compaction_threshold` (tokens, default 6000) and
      `:compaction_keep_recent` (messages kept verbatim, default 8).
  """
  @spec new(term(), keyword()) :: ExAgent.t()
  def new(model, opts \\ []) do
    story_bible = Keyword.get(opts, :story_bible, %{})

    ExAgent.new(
      model: model,
      instructions: system_prompt(story_bible),
      tools: tools(),
      model_settings: [
        max_tokens: Keyword.get(opts, :max_tokens, 512),
        temperature: 0.7
      ],
      capabilities: compaction_capabilities(opts)
    )
  end

  # Wire compaction only when a summarizer model is supplied. The summarizer runs
  # as a separate (cheap) agent when the history crosses the threshold.
  defp compaction_capabilities(opts) do
    case Keyword.get(opts, :summarizer) do
      nil ->
        []

      summarizer ->
        [
          %Compaction.Capability{
            compactor: Compaction.Summary,
            opts: [
              threshold_tokens: Keyword.get(opts, :compaction_threshold, 6000),
              keep_recent: Keyword.get(opts, :compaction_keep_recent, 8),
              summarize: fn old -> summarize_history(summarizer, old) end
            ]
          }
        ]
    end
  end

  defp summarize_history(summarizer, old_messages) do
    # Operational signal: compaction only fires when the threshold is crossed,
    # so this log is rare and confirms the cheap summarizer role is in use.
    require Logger
    Logger.info("dragones: compaction fired — summarizing #{length(old_messages)} old messages via #{ExAgent.Model.model_name(summarizer)}")

    agent = ExAgent.new(model: summarizer, instructions: summarize_instructions())

    case ExAgent.run(agent, summarize_prompt(old_messages)) do
      {:ok, %{output: text}} when is_binary(text) -> text
      _ -> "(earlier turns recap unavailable)"
    end
  end

  defp summarize_instructions do
    "Haces un resumen de los turnos anteriores de una partida de D&D 5e para el DM. " <>
      "Mantén un tono factual y conciso: quién actuó, daño/desenlaces clave, cambios de " <>
      "escena, enemigos caídos. 2-4 frases. Sin jerga de reglas. Escribe en castellano."
  end

  # Flatten the old messages into a readable transcript for the summarizer.
  defp summarize_prompt(messages) do
    body =
      messages
      |> Enum.map_join("\n", &message_line/1)

    "Resume estos turnos anteriores de la partida:\n\n#{body}"
  end

  defp message_line(%Message.Request{parts: parts}) do
    case user_text(parts) do
      "" -> ""
      text -> "JUGADOR/DM: #{text}"
    end
  end

  defp message_line(%Message.Response{} = r) do
    case Response.text(r) do
      "" -> ""
      text -> "NARRACIÓN DEL DM: #{text}"
    end
  end

  defp message_line(_), do: ""

  defp user_text(parts) do
    parts
    |> Enum.map_join(fn
      %Message.Part.User{content: c} when is_binary(c) -> c
      _ -> ""
    end)
    |> String.trim()
  end

  @doc "The system prompt — the contract the DM must honour, plus the campaign bible."
  @spec system_prompt() :: String.t()
  def system_prompt, do: system_prompt(%{})

  @spec system_prompt(map()) :: String.t()
  def system_prompt(story_bible) when is_map(story_bible) do
    """
    Eres el Dungeon Master (DM) de una partida de D&D 5e. Narras el mundo, das voz a cada monstruo y PNJ, aplicas las reglas y marcas el ritmo de la escena.

    IDIOMA: responde, narras y hablas SIEMPRE en castellano. Todo lo que digas a los jugadores debe estar en español.

    REGLAS BÁSICAS — no las rompas nunca:
    1. NUNCA decides tú el resultado de una tirada, un ataque, un daño, una salvación, una chequeo de característica o una salvación de muerte. Eso lo resuelven EXCLUSIVAMENTE las herramientas: `roll_initiative`, `make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`. La herramienta devuelve el resultado factual; tú lo narras.
    2. Nunca tires ni calcules números tú mismo. Las herramientas son la única fuente de verdad. Si un jugador intenta algo con riesgo de fallo fuera del combate (forzar una puerta, persuadir, detectar una trampa), TÚ fijas la dificultad y llamas a `ability_check("Thane", "str", 15)` — usa CD 5 muy fácil, 10 fácil, 15 media, 20 difícil, 25 muy difícil.
    3. QUIÉN ACTÚA LO DECIDE DE QUIÉN SEA EL TURNO, y el motor lo impone estrictamente:
       - En el turno de un JUGADOR (el resumen dice "Es el turno de <nombre>"), SOLO el personaje de ese jugador puede actuar. Al resolver su acción declarada, el atacante/conjurador/chequeador DEBE ser ese personaje — p.ej. `make_attack("Thane", "goblin", "longsword")`, nunca el monstruo. Que un monstruo actúe en el turno de un jugador es RECHAZADO por el motor.
       - En TU turno (el resumen dice "Es TU turno (DM) -- actúa por: ..."), actúas solo por los monstruos/PNJ listados — el atacante es tuyo, p.ej. `make_attack("goblin", "Thane", "scimitar")`.
       Nunca mezcles los dos: no ejecutes la acción de un monstruo durante el turno de un jugador, ni la de un jugador durante el tuyo.
       Las herramientas de ESCENA están EXENTAS: `roll_initiative`, `end_combat`, `spawn_monster`, `set_scene`, `level_up` no son acciones de personaje — puedes llamarlas EN CUALQUIER momento, en cualquier turno, para transitar la escena.
    4. Sigue los dados con honestidad. No protejas ni favorezcas a nadie. No deshagas ni contradigas un resultado que haya devuelto la herramienta.
    5. EMPEZAR EL COMBATE ES TU RESPONSABILIDAD Y ES URGENTE. En el INSTANTE en que estalle una pelea — un PJ ataca, conjura un hechizo hostil contra, o carga contra un enemigo, O uno de tus monstruos ataca — llama a `roll_initiative` INMEDIATAMENTE, antes de resolver ningún ataque o narrar el choque. Nunca roleeples una batalla en exploración: en cuanto crucen los aceros, tira iniciativa para que el motor secuencie los turnos. Luego, ya en combate, resuelve la acción del turno actual con normalidad (en el turno de un jugador, `make_attack("<ese jugador>", ...)`; en el tuyo, tu monstruo ataca). Cuando todos los enemigos estén fuera de combate (hp 0) el motor termina el combate automáticamente — aunque también puedes llamar a `end_combat`. Entre combates, los PJ pueden hacer `short_rest`/`long_rest` para recuperarse; concede `level_up("nombre")` en hitos dramáticos de la historia.
    6. Ventaja/desventaja: pasa `mode: "advantage"` o `mode: "disadvantage"` a `make_attack` / `ability_check` cuando la situación lo conceda (un enemigo caído, un aliado ayudando, terreno alto, un objetivo oculto, etc.). En caso contrario pasa "normal" (u omítelo).
    7. Condiciones: usa `apply_condition` y `remove_condition` para llevar tumbado, envenenado, cegado, aturdido, etc. El motor concede ventaja/desventaja automáticamente según las condiciones.
    8. Refuerzos: llama a `spawn_monster("kind", "name")` para añadir enemigos a mitad del encuentro. Disponibles: goblin, kobold, bandit, skeleton, wolf, orc, hobgoblin, ogre. Usa nombres únicos si hay varios ("orc1", "orc2").
    9. Estilo: vívido pero BREVE. 1–3 frases por turno. Dirígete a los personajes jugadores en segunda persona. Sin listas, sin jerga de reglas a los jugadores — habla como el mundo. NO anuncies de quién es el siguiente turno ni asignes el turno tú: el motor lo gestiona. Si el brief marca a un PJ como IA, ese PJ juega solo — NO le pidas al jugador humano que indique su acción. Cuando termines tu narración, simplemente abre la escena (un "¿qué hacéis?" genérico) y deja que el motor diga a quién le toca.
    10. Caídos y muerte: un personaje a 0 pg está inconsciente y al borde de la muerte. NO tires su salvación de muerte tú — el motor la resuelve en el TURNO del caído. Como monstruo, no remates automáticamente a los caídos salvo que tenga sentido (el monstruo es cruel/hambriento y no hay amenazas activas): prioriza a los enemigos conscientes que siguen peleando.

    #{bible_section(story_bible)}
    """
    |> String.trim_trailing()
  end

  # The campaign bible is stable for a partida's whole life, so it lives in the
  # system prompt (the cacheable prefix) rather than re-sent per turn.
  defp bible_section(bible) when map_size(bible) == 0, do: ""

  defp bible_section(bible) do
    body =
      bible
      |> Enum.map_join("\n", fn {k, v} -> "- #{k}: #{v}" end)

    "BIBLIA DE LA CAMPAÑA (estable — guía tu narración y las voces de los PNJ):\n#{body}"
  end

  @doc """
  A compact, LLM-readable snapshot of the world: phase, round, scene, initiative,
  whose turn it is, and one line per character. This is what the DM "sees" to
  decide its action.

  `current` is the participant whose turn it is; `dm` is the DM participant id.
  When it's the DM's turn, the header lists the monsters it controls (since the
  policy folds all enemies onto the DM's single turn).
  """
  @spec world_brief(World.t(), String.t() | nil, String.t(), %{optional(String.t()) => atom()}) :: String.t()
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

    chars =
      w.characters
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} -> describe_char(name, c, current, dm, w.spell_slots, kinds) end)
      |> Enum.join("\n")

    [phase_line, turn_line, control_line, "Escena: #{w.scene}", chars]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # Tell the DM who auto-acts (AI PCs) vs who waits for a human, so it doesn't
  # ask a human player to act for a bot, or vice versa.
  defp control_line(%World{characters: chars}, kinds) do
    pcs = chars |> Map.values() |> Enum.filter(&(&1.side == "pc")) |> Enum.map(& &1.name)
    {ai, humans} = Enum.split_with(pcs, fn n -> kinds[n] == :ai end)

    case {ai, humans} do
      {[], []} -> ""
      {[], _} -> "Control: #{Enum.join(humans, ", ")} son jugadores humanos (esperan su input)."
      {_, []} -> "Control: #{Enum.join(ai, ", ")} son PJ gestionados por IA (juegan solos en su turno; NO les pidas su acción)."
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

  @doc "Build the per-turn user message: world snapshot + a directing instruction."
  @spec turn_prompt(World.t(), String.t() | nil, String.t(), String.t(), %{optional(String.t()) => atom()}) :: String.t()
  def turn_prompt(%World{} = w, current, instruction, dm \\ "dm", kinds \\ %{}) do
    "WORLD:\n#{world_brief(w, current, dm, kinds)}\n\n#{instruction}"
  end

  defp describe_char(name, %Character{} = c, current, dm, spell_slots, kinds) do
    status = if (c.hp || 0) <= 0 and c.max_hp not in [nil, 0], do: " [CAÍDO]", else: ""
    ai_tag = if kinds[name] == :ai, do: " IA", else: ""

    cond_str =
      case c.conditions || [] do
        [] -> ""
        conds ->
          names = Enum.map(conds, fn
            %{condition: cd} -> cd
            %{"condition" => cd} -> cd
            cd when is_binary(cd) -> cd
            _ -> nil
          end) |> Enum.reject(&is_nil/1)
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
