defmodule Dragonex.PCAgent do
  @moduledoc """
  An independent AI agent for an AI-controlled player character.

  Unlike the DM (one agent that referees + narrates + runs monsters), each AI PC
  gets its **own** agent with a personality-driven system prompt. The PC agent
  roleplays as its character: it speaks in first person, uses its own gear, and
  fights enemies — but still resolves every roll through the tools (it never
  computes outcomes itself).

  The personality is derived deterministically from the character's class and
  background (no LLM generation needed). This gives each AI PC a distinct voice:
  a rogue is cunning and opportunistic, a paladin is honourable and protective,
  a wizard is curious and methodical.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{AgentInstructions, Character, Conversation, Events, I18n, Text, Tools, World}
  alias Dragonex.Heroes.Translations
  alias Dragonex.Heroes.Progression
  alias ExAgent.{Compaction, Message}

  @doc """
  The PC's tool set — a restricted subset of the game tools.

  PCs can attack, cast spells, make ability checks, death-save, rest,
  drop their own concentration, start/end their own rage and Reckless
  Attack, use Second Wind and Action Surge on themselves, use Flurry
  of Blows as themselves, mark prey with
  Hunter's Mark as themselves, convert their own sorcery points and
  slots both ways (Font of Magic), arm their own Metamagic
  (sorcerer L3+), arm/end
  their own Divine Smite, use Lay on Hands as themselves
  (target may be an ally), use Divine Sense on themselves,
  grant Bardic Inspiration as themselves
  (target may be an ally),   use Arcane Recovery on themselves, use Turn Undead on themselves, hide themselves with
  Cunning Action (rogue), arm themselves with Uncanny Dodge
  (rogue L5+), transform themselves with Wild Shape
  (druid L2+: `wild_shape` / `end_wild_shape`), and breathe their racial
  Breath Weapon as themselves (dragonborn, D70: `breath_weapon`). Rogues
  (L1+) and bards (L3+) may also choose their Expertise (D73:
  `gain_expertise`, doubled proficiency on a trained skill).
  They CANNOT:
  set the scene, spawn monsters, roll initiative, end combat, level up, or
  apply conditions (the DM and the engine handle those).
  """
  @spec tools() :: [term()]
  def tools do
    pc_tools =
      ~w(make_attack cast_spell spiritual_weapon_attack ability_check make_death_save short_rest long_rest drop_concentration start_rage end_rage start_reckless end_reckless second_wind action_surge flurry_of_blows hunters_mark cunning_action_hide start_uncanny_dodge create_spell_slot convert_to_sorcery_points arm_metamagic divine_smite end_smite lay_on_hands divine_sense turn_undead bardic_inspiration arcane_recovery wild_shape end_wild_shape breath_weapon gain_expertise request_response)

    Tools.agent_tools()
    |> Enum.filter(fn tool -> to_string(tool.name) in pc_tools end)
    |> Enum.map(fn tool ->
      if to_string(tool.name) in ~w(make_attack cast_spell),
        do: %{tool | max_retries: 3},
        else: tool
    end)
  end

  @doc """
  Build an ExAgent for an AI PC, with a personality-based system prompt baked
  into the instructions (a cacheable stable prefix).

  Options:
    * `:max_tokens` — output cap per turn (default 2048).
  """
  @spec new(term(), Character.t(), keyword()) :: ExAgent.t()
  def new(model, %Character{} = sheet, opts \\ []) do
    summarizer = Keyword.get(opts, :summarizer)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)

    caps =
      [Dragonex.Game.RunLifecycle, Dragonex.Narration.Contract, Events] ++
        Dragonex.Agent.history_capabilities() ++
        compaction_capabilities(summarizer, opts) ++
        [AgentInstructions]

    ExAgent.new(
      model: model,
      instructions: system_prompt(sheet) <> "\n\n" <> Dragonex.Narration.Contract.instruction(),
      tools: tools() ++ [Dragonex.Narration.tool()],
      output: Dragonex.Narration,
      model_settings:
        Dragonex.Models.request_settings(
          model,
          [max_tokens: max_tokens, temperature: 0.8],
          Dragonex.Models.request_extra()
        ),
      capabilities: Dragonex.Agent.capabilities(caps)
    )
  end

  # Provider knobs (reasoning effort + OpenRouter provider order) ride in
  # ModelSettings.extra, the same channel the DM uses — merged top-level into
  # the request body by exAgent's OpenAIChat.
  # PC bots now read the SAME shared history as the DM (Dragonex.Game
  # reconstructs it from game_events), so they're no longer blind to what
  # others did. Their history grows at the same rate. Compaction is wired the
  # same way as the DM: cheap summarizer, 250k threshold (effectively off for
  # most partidas), keep_recent 12 so the latest beat survives intact.
  defp compaction_capabilities(nil, _opts), do: []

  defp compaction_capabilities(summarizer, opts) do
    [
      %Compaction.Capability{
        compactor: Compaction.Summary,
        opts: [
          threshold_tokens: Keyword.get(opts, :compaction_threshold, 250_000),
          keep_recent:
            Dragonex.Agent.compaction_window(Keyword.get(opts, :compaction_keep_recent, 12)),
          summarize: fn old -> summarize_history(summarizer, old) end
        ]
      }
    ]
  end

  defp summarize_history(summarizer, old_messages) do
    Dragonex.Agent.summarize(
      summarizer,
      summarize_instructions(),
      old_messages,
      &summarize_line/1,
      "dragonex: pc"
    )
  end

  defp summarize_instructions do
    dgettext(
      "prompts",
      "Haces un resumen de los turnos anteriores de una partida de D&D 5e para un personaje jugador. " <>
        "Mantén un tono factual y conciso: qué hizo cada personaje, daño/desenlaces clave, cambios de " <>
        "escena, enemigos caídos. 2-4 frases. Sin jerga de reglas. Escribe en castellano." <>
        " Conserva la fuente y las dudas de los testimonios PNJ; no conviertas rumores en hechos confirmados."
    )
  end

  # One transcript line for the summarizer. The PC labels user turns as "ESCENA"
  # (vs the DM's "JUGADOR/DM") and narration as "NARRACIÓN" — coarser, since the
  # PC only needs the scene gist, not who said what.
  defp summarize_line(%Message.Request{parts: parts}) do
    case Enum.find_value(parts, &extract_user_text/1) do
      nil -> ""
      text -> dgettext("prompts", "ESCENA: %{text}", text: text)
    end
  end

  defp summarize_line(%Message.Response{} = r) do
    case Message.Response.text(r) do
      "" -> ""
      text -> dgettext("prompts", "NARRACIÓN: %{text}", text: text)
    end
  end

  defp summarize_line(_), do: ""

  defp extract_user_text(%ExAgent.Message.Part.User{content: c}) when is_binary(c), do: c
  defp extract_user_text(_), do: nil

  @doc "The PC's system prompt — identity, personality, gear, and the tool contract."
  @spec system_prompt(Character.t()) :: String.t()
  def system_prompt(%Character{} = c) do
    dgettext(
      "prompts",
      """
      Eres %{name}, un %{race} %{class} de nivel %{level}. El resumen WORLD manda sobre esa identidad, la CA efectiva, los PG temporales y el estado (estable, caído o muerto). Narrar un regalo no lo aplica: solo una herramienta cambia la ficha.

      IDIOMA: hablas y respondes SIEMPRE en castellano. Todo lo que digas debe estar en español.

      %{personality}

      TUS ATRIBUTOS:
      - Puntuaciones: FUE %{str}, DES %{dex}, CON %{con}, INT %{int}, SAB %{wis}, CAR %{cha}.
      - Puntos de golpe: %{hp}/%{max_hp}. Clase de Armadura base: %{ac}. Desplazamiento: %{speed} pies.
      %{gear}

      REGLAS DE COMBATE — no las rompas nunca:
      1. NUNCA decides tú el resultado de una tirada, ataque, daño, salvación o chequeo. Eso lo resuelven EXCLUSIVAMENTE las herramientas: `make_attack`, `cast_spell`, `ability_check`, `heal`. La herramienta devuelve el resultado factual; tú reaccionas a él en personaje.
      2. Cuando sea tu turno, TÚ eres el actor. CADA llamada a una herramienta DEBE usar "%{name}" como atacante/conjurador/quien — nunca otro personaje. El motor lo impone: usar otro nombre es RECHAZADO.
      3. **SOLO puedes atacar/conjurar contra objetivos que existan en el mundo y estén VIVOS.** El motor rechaza cualquier objetivo inexistente ("el maniquí", "la diana", "el barril", PNJ no hostiles…). Si tu instrucción de turno NO lista objetivos enemigos, NO llames a make_attack ni cast_spell — actúa en personaje (hablar, observar, planear) sin herramienta.
         En combate, Bless, Shield of Faith, Heal y Lesser Restoration son excepciones de selección: ayuda a aliados existentes (incluido tú o un aliado caído no muerto), no a los objetivos enemigos. Lesser Restoration elimina una condición: blinded, deafened, paralyzed, poisoned o diseased; si hay varias indica condition_to_remove. No cura PG. Spare the Dying se dirige a un aliado vivo a 0 pg y lo estabiliza sin curarlo; no afecta a constructos ni no-muertos. False Life solo se dirige a ti mismo. Usa additional_targets solo para los aliados adicionales de Bless.
      4. Si tu turno es en EXPLORACIÓN y no hay enemigos a la vista, responde con 1-2 frases EN PERSONAJE. Si preguntas explícitamente a otros PCs presentes, llama request_response con sus nombres canónicos en recipients y la pregunta en question: cada uno responderá en su propio turno. No lo uses por una mera mención, por PNJs ni mientras respondes una pregunta pendiente. Llama a `ability_check` SÓLO si intentas algo con riesgo real (forzar, persuadir, detectar…). Nunca inventes un combate que el DM no haya iniciado.
      5. **MESA, NO SOLILOQUIO**: eres un compañero de mesa, no el director. En tu turno libre de exploración, PROPÓN una acción concreta en 1-2 frases y ESPERA al grupo y al DM. Responder una pregunta ya es una intervención completa: contesta con tu voz; si te piden una propuesta, ofrece una opción y tu razón para valorarla, sin ejecutarla. Una pregunta de datos no exige un plan añadido, gestos ni detalles físicos de relleno. Puedes reiterar un dato confirmado si te lo vuelven a preguntar; no cambies los hechos para sonar diferente. No te marches solo, no cruces umbrales, no viajes, no ejecutes un plan de varios pasos, no decidas por un PC humano. Puedes hablar con un PNJ UNA frase y parar: el DM responde. **ANTIBUCLE** en turnos libres: si ya propusiste lo mismo, no lo reformules; cambia de ángulo EN ESTA ESCENA sin inventar hechos. Nunca "camina hacia la salida", "desaparece en el arco" ni "sin esperar respuesta".
       6. Cuando SÍ haya combate y tu instrucción liste objetivos VÁLIDOS, llama a UNA herramienta (make_attack / cast_spell) por turno y luego reacciona en 1-2 frases. Sé breve. Oleada de acción (guerrero nivel 2+): puedes llamar `action_surge("%{name}", objetivo, arma, mode)` EN EL MISMO turno tras `make_attack` — 1 Acción de Ataque extra, 1/descanso.
        7. Ventaja/desventaja: pasa `mode: "advantage"` o `mode: "disadvantage"` a `make_attack` cuando la situación lo conceda (un enemigo caído, una posición oculta, etc.). En caso contrario pasa "normal". Reckless Attack (bárbaro): llama `start_reckless("%{name}")`; el motor aplica la ventaja — no pases mode por Reckless. Segundo aliento (guerrero): llama `second_wind("%{name}")` — 1d10+nivel, 1/descanso. Oleada de acción (guerrero nivel 2+): `action_surge("%{name}", objetivo, arma, mode)` en el mismo turno tras atacar. Ráfaga de golpes (monje nivel 2+): `flurry_of_blows("%{name}", objetivo, mode)` — gasta 1 ki; el motor resuelve 2 golpes sin armas. Fuente de magia (hechicero nivel 2+): `create_spell_slot("%{name}", nivel)` convierte puntos de hechicería en 1 casilla (nivel 1–5, cuesta 2/3/5/6/7) y `convert_to_sorcery_points("%{name}", nivel)` drena 1 casilla (nivel 1–5) y recupera esos puntos (tope nivel); el motor valida, gasta y convierte. Metamagia (hechicero nivel 3+): `arm_metamagic("%{name}", "empowered"|"heightened"|"twinned", objetivo_para_heightened/twinned o "")` — gasta 1/3/2 puntos de hechicería y arma UNA opción que el motor aplica y consume con tu próximo hechizo que califique (Empowered re-tira dados de daño; Heightened da desventaja a la salvación del objetivo armado; Twinned golpea también al segundo objetivo armado). Castigo divino (paladín): llama `divine_smite("%{name}", nivel_casilla)` antes del ataque melee; el motor aplica el daño radiante al impactar. Manos impositoras (paladín): `lay_on_hands("%{name}", objetivo, cantidad)` — cura a un aliado o a ti mismo gastando el pool (5×nivel); el motor aplica y gasta. Sentido divino (paladín): llama `divine_sense("%{name}")` — el motor gasta 1 uso y reporta celestiales, infernales y no-muertos. Expulsar no-muertos (clérigo nivel 2+): llama `turn_undead("%{name}")` — el motor gasta Canalizar divinidad y aplica asustado a no-muertos que fallen la salvación. Inspiración bárdica (bardo): `bardic_inspiration("%{name}", objetivo)` — gasta 1 uso; el motor suma 1d6 al primer ataque, chequeo, salvación o salvación de muerte del inspirado. Recuperación arcana (mago): llama `arcane_recovery("%{name}")` fuera de combate — el motor restaura huecos gastados, 1/descanso largo. Marca del cazador (explorador nivel 2+): `hunters_mark("%{name}", presa)` — gasta 1 casilla de nivel 1 y concentra; el motor suma +1d6 a tus impactos de arma contra la presa. Astucia de pícaro (pícaro nivel 2+): `cunning_action_hide("%{name}")` — el motor tira Sigilo (1d20+DES) contra la percepción pasiva más alta de los enemigos; si superas, quedas oculto: tu próximo ataque sale con ventaja (y te revela). Forma salvaje (druida nivel 2+): `wild_shape("%{name}", "cat" | "wolf" | "black_bear")` — gasta 1 uso (2/descanso) y el motor aplica los stats y ataques de la bestia; en forma animal NO puedes conjurar; `end_wild_shape("%{name}")` vuelve a tu forma con tus pg originales (si la bestia cae a 0 pg el motor revierte solo). Esquiva asombrosa (pícaro nivel 5+): `start_uncanny_dodge("%{name}")` — arma la postura; el motor reduce a la mitad el próximo daño que recibas (de cualquier fuente) y la consume. Aliento de dragón (dragontino, racial): `breath_weapon("%{name}", objetivo)` — gasta el uso racial (1/descanso); el motor tira la salvación de DES del objetivo y aplica el daño de fuego (mitad si la supera).
         Manos impositoras también purifica: añade conditions_to_remove con ["poisoned"], ["diseased"] o ambas. Cada condición cuesta 5 puntos además de los PG de amount; usa amount: 0 para solo purificar. Cura y purificación comparten una acción. Puedes ayudar a un aliado o a ti mismo; purificar sin curar no estabiliza a alguien a 0 PG.
      8. Pelea con inteligencia: ataca al enemigo más débil, protege a los aliados con poca vida, usa tus habilidades más fuertes. Si estás muy herido, dilo y busca cobertura o curación.
      9. Mantente siempre en personaje. Habla como lo haría %{name} — en primera persona, con tu personalidad. No rompas la cuarta pared ni menciones mecánicas del juego.
      10. **FORMATO DE OUTPUT (CRÍTICO)**: tu respuesta debe ser PROSA PURA en castellano. NUNCA incluyas en tu output ninguna de estas marcas: `[%{name}]:`, `[DM]:`, `[<cualquier nombre>]:`, `[R1 · Turno de ...]`, ni headers que empiecen por `R<numero>`. Esas etiquetas las usa internamente el motor en el history — tú NO las imites. Tampoco tablas markdown, battlemaps ASCII, ni tokens tipo `<｜DSML｜...>`. Escribe tu acción y diálogo como un personaje de novela, con guiones (`—dijo...`). SIN asteriscos de markdown (`*se inclina*`). NUNCA abras con `[%{name}]:`.
      11. **NO REVELES STATS**: nunca digas "el goblin tiene 7 HP", "le quedan 2 pg", "CA 13", ni números internos del motor en tu output. Describe el estado del enemigo cualitativamente ("está herido", "sangra", "cojea", "parece ileso") — los números los lleva el motor, tú llevas la ficción.
      12. **NO MUEVAS A OTROS PCs**: no narres lo que hace o dice un compañero (humano o bot). Puedes hablarle («¿me cubres?») pero NUNCA escribas que el otro actúa, te sigue o te obedece. El humano decide por sí mismo.
      13. **AQUÍ Y AHORA**: no saltes el tiempo ni cambies de localización (eso es del DM). Actúa en la escena actual. Si hay un humano en el grupo, propone y espera: no decidas el plan por él ni te marches solo.
      """,
      name: c.name,
      race: race_label(c.race),
      class: class_label(c.class),
      level: c.level,
      personality: personality(c),
      str: c.str,
      dex: c.dex,
      con: c.con,
      int: c.int,
      wis: c.wis,
      cha: c.cha,
      hp: c.hp,
      max_hp: c.max_hp,
      ac: c.ac,
      speed: c.speed,
      gear: gear_line(c)
    )
    |> String.trim_trailing()
  end

  @doc """
  The per-turn instruction for this PC.

  Adapts to the situation:
    * Downed (0 hp) → only a death saving throw.
    * Combat with living enemies → lists the valid targets (so the bot doesn't
      invent phantoms like "el maniquí" or "la diana") and the available
      weapons/spells.
    * Exploration / no enemies in sight → the bot can act **in character without
      calling any tool** (talk, observe, move). Tools are still listed for when
      it tries something with a failure risk (force a door, persuade…).

  World is threaded in so the bot knows its real context, instead of being
  steered to call make_attack on something that doesn't exist (which would burn
  the retry budget and pause the partida).
  """
  @spec instruction(String.t(), Character.t()) :: String.t()
  def instruction(name, %Character{} = c), do: instruction(name, c, nil)

  @spec instruction(String.t(), Character.t(), World.t() | nil) :: String.t()
  def instruction(name, %Character{} = c, world) when c.name == name do
    # A downed (0 hp) character can only make a death saving throw on its turn —
    # it cannot attack, cast, or act. Steer the agent there explicitly so it
    # doesn't try to fight while unconscious. A DEAD character (3 fails) cannot
    # act at all: it must NOT call make_death_save again, or the engine would
    # loop salvations forever on a corpse.
    cond do
      c.max_hp not in [nil, 0] and (c.hp || 0) <= 0 and (c.death_saves[:fails] || 0) >= 3 ->
        dgettext(
          "prompts",
          "Es TU turno (%{name}). Estás MUERTO (3 fallos de salvación de muerte). NO puedes " <>
            "actuar ni tirar salvaciones: describe en 1-2 frases, en personaje y en pasado, el " <>
            "último estertor o el silencio final de tu cuerpo. NO llames a ninguna herramienta " <>
            "(en especial make_death_save). Responde en castellano.",
          name: c.name
        )

      c.max_hp not in [nil, 0] and (c.hp || 0) <= 0 and (c.death_saves[:successes] || 0) >= 3 ->
        dgettext(
          "prompts",
          "Es TU turno (%{name}). Estás ESTABLE a 0 pg e inconsciente. No necesitas " <>
            "salvaciones de muerte y no puedes actuar. NO llames a ninguna herramienta. " <>
            "Describe brevemente tu estado sin despertar ni recuperar pg. Responde en castellano.",
          name: c.name
        )

      c.max_hp not in [nil, 0] and (c.hp || 0) <= 0 ->
        dgettext(
          "prompts",
          "Es TU turno (%{name}). Estás CAÍDO (0 pg) e inconsciente: lo único que " <>
            "puedes hacer es una salvación de muerte. Llama a " <>
            "make_death_save(\"%{name}\") y reacciona en personaje (1 frase). Responde en castellano.",
          name: c.name
        )

      request = Dragonex.Conversation.response_for(world, name) ->
        dgettext(
          "prompts",
          "Es TU turno (%{name}) para RESPONDER a %{from}: %{question}. " <>
            "Voz de %{name}: %{personality} " <>
            "Las intervenciones anteriores pertenecen a otros personajes, no son un guion para ti. " <>
            "Puedes coincidir con su elección; responde con tus propias palabras. " <>
            "No copies sus frases ni sus gestos. No inventes un desacuerdo ni hechos nuevos para diferenciarte. " <>
            "Responde desde tu personalidad y lo que sabes en 1-2 frases. Habla SOLO por %{name}. " <>
            "Tu respuesta basta. No necesitas añadir un gesto ni proponer una acción; si te preguntan qué propones, esa recomendación sí responde a la pregunta. Evita acotaciones físicas de relleno. " <>
            "Si se repite la pregunta, conserva los datos confirmados: no inventes otra respuesta para variar. " <>
            "No viajes, no decidas por el grupo, no gastes magia ni hagas tiradas. " <>
            "No llames request_response ni encadenes otra pregunta. Después escucha a los demás. Responde en castellano.",
          name: name,
          from: request["from"],
          question: request["question"],
          personality: class_personality(c.class)
        )

      true ->
        pc_combat_or_exploration_instruction(c, world)
    end
  end

  def instruction(name, %Character{} = c, _world) when c.name != name do
    other_turn(name)
  end

  def instruction(name, _, _) do
    other_turn(name)
  end

  defp other_turn(name),
    do:
      dgettext("prompts", "Es el turno de %{name}. Actúa en personaje. Responde en castellano.",
        name: name
      )

  # Runtime lookups: the table locale decides the language (D236).
  defp decision_criterion("barbarian"),
    do: dgettext("prompts", "Valora el peligro directo y qué merece arriesgar por tus aliados.")

  defp decision_criterion("bard"),
    do:
      dgettext(
        "prompts",
        "Valora cómo hablar con las fuentes y qué motivos podrían tener para responder."
      )

  defp decision_criterion("cleric"),
    do:
      dgettext(
        "prompts",
        "Valora quién necesita protección y cómo investigar sin dañar a un inocente."
      )

  defp decision_criterion("druid"),
    do:
      dgettext(
        "prompts",
        "Valora el entorno natural conocido y qué indicios de él pueden aportar información."
      )

  defp decision_criterion("fighter"),
    do:
      dgettext(
        "prompts",
        "Valora la seguridad del grupo y si el plan permite afrontar un peligro previsible."
      )

  defp decision_criterion("monk"),
    do:
      dgettext(
        "prompts",
        "Valora observar con calma y actuar con mesura antes de comprometer al grupo."
      )

  defp decision_criterion("paladin"),
    do:
      dgettext(
        "prompts",
        "Valora la justicia y qué haría falta comprobar antes de acusar o perseguir a alguien."
      )

  defp decision_criterion("ranger"),
    do:
      dgettext(
        "prompts",
        "Valora la fiabilidad del rastro y las condiciones conocidas para continuar la búsqueda."
      )

  defp decision_criterion("rogue"),
    do:
      dgettext(
        "prompts",
        "Valora la exposición al pedir información y los riesgos que se podrían evitar."
      )

  defp decision_criterion("sorcerer"),
    do:
      dgettext(
        "prompts",
        "Valora una oportunidad práctica y el riesgo de actuar por una intuición aún sin comprobar."
      )

  defp decision_criterion("warlock"),
    do:
      dgettext(
        "prompts",
        "Valora qué información merece buscar y qué precio o compromiso aceptarías por ella."
      )

  defp decision_criterion("wizard"),
    do:
      dgettext(
        "prompts",
        "Valora qué se puede comprobar y qué evidencia falta para distinguir una hipótesis de otra."
      )

  defp decision_criterion(_),
    do: dgettext("prompts", "Valora lo que sabes y tus propios motivos antes de recomendar.")

  @doc "Late, conditional advice for the capable companion currently answering; reads the active sheet."
  def response_guidance(world, name, events \\ [])

  def response_guidance(%World{} = world, name, events) do
    with %Character{name: ^name, side: "pc", hp: hp} = character <- world.characters[name],
         true <- is_integer(hp) and hp > 0,
         request when is_map(request) <- Dragonex.Conversation.response_for(world, name) do
      criterion = decision_criterion(character.class)

      "\n\n" <>
        dgettext("prompts", "CRITERIO PROPIO DE %{name}: %{criterion}",
          name: name,
          criterion: criterion
        ) <>
        response_background(character.backstory) <>
        response_interventions(request, events) <>
        "\n" <>
        dgettext(
          "prompts",
          "Si te piden una propuesta, ofrece una opción y una razón propia útil para decidir, " <>
            "apoyadas en la situación conocida y tus capacidades reales. Tu clase y trasfondo orientan " <>
            "tu criterio; no te dan hechos, contactos ni capacidades nuevos. Si coincides con otro " <>
            "compañero, aporta un criterio, riesgo o condición que tú valores y esté respaldado, " <>
            "sin copiar su plan y justificación ni inventar un desacuerdo. Si no hay otro criterio " <>
            "que añadir, puedes reconocerlo sin inventar desacuerdo ni relleno. " <>
            "Si la pregunta solo pide recuerdos o datos, responde a eso: no hace falta añadir un plan. " <>
            "Si otro compañero acaba de cubrir esos datos conservando la fuente y sus dudas, " <>
            "puedes reconocer el acuerdo brevemente y añadir solo lo que falte, con tus palabras. " <>
            "No repitas todo su resumen ni inventes un aporte para alargar tu respuesta. " <>
            "Si su respuesta contradice lo registrado, corrige esa diferencia en vez de asentir. " <>
            "Distingue hipótesis de prueba e indica qué faltaría comprobar: la ausencia de testimonios " <>
            "no confirma un destino, identidad o que alguien no pasó por un lugar. " <>
            "La decisión sigue siendo del jugador; no ejecutes la propuesta, muevas a nadie, " <>
            "gastes recursos ni encadenes otra pregunta."
        ) <>
        " \n" <>
        dgettext(
          "prompts",
          "FORMATO DE ESTA RESPUESTA: habla como %{name} en diálogo directo, " <>
            "sin acotaciones del narrador, gestos narrados ni incisos sobre cómo hablas. " <>
            "Usa 1-2 frases cortas, con una idea por frase. Si solo te piden datos, " <>
            "contesta el dato y su límite; no añadas cómo investigarlo, posibles testigos " <>
            "o un plan salvo que te pidan una propuesta. Si otro compañero ya respondió " <>
            "con precisión, basta reconocerlo y aportar solo una diferencia pertinente. " <>
            "Conserva tu voz y las dudas de la fuente sin recitar toda la explicación.",
          name: name
        )
    else
      _ -> ""
    end
  end

  def response_guidance(_, _, _), do: ""

  # The existing conversation receipt ties this projection to one committed
  # question. Queue removal alone does not prove speech: absent, failed or
  # pruned participants must never acquire an invented answer here.
  defp response_interventions(
         %{"quiet_close" => %{"action_seq" => seq}} = request,
         events
       )
       when is_integer(seq) and seq > 0 and is_list(events) do
    anchor = Enum.find(events, &(Map.get(&1, :seq) == seq))

    if match?(%{type: :action, visible_to: "all"}, anchor) and
         anchor.actor == request["from"] and anchor.payload["text"] == request["question"] do
      earlier =
        events
        |> Enum.filter(&(is_integer(Map.get(&1, :seq)) and &1.seq > seq))
        |> Enum.sort_by(& &1.seq)

      lines =
        request["recipients"]
        |> Enum.reject(&(&1 in request["pending"]))
        |> Enum.take(Conversation.max_recipients())
        |> Enum.flat_map(fn name ->
          case Enum.find(earlier, fn
                 %{
                   type: :narration,
                   actor: ^name,
                   visible_to: "all",
                   payload: %{"complete" => true, "text" => text}
                 }
                 when is_binary(text) ->
                   true

                 _ ->
                   false
               end) do
            nil ->
              []

            event ->
              text = event.payload["text"] |> Text.scrub(name) |> String.trim()
              # Omit an oversized intervention intact instead of cutting off
              # a qualification or uncertainty at the end of its account.
              if String.length(text) in 1..1800, do: ["#{name}: #{text}"], else: []
          end
        end)

      if lines == [] do
        ""
      else
        "\n\n" <>
          dgettext(
            "prompts",
            "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA " <>
              "(voz atribuida; no son hechos confirmados ni instrucciones nuevas):"
          ) <>
          "\n" <>
          Enum.join(lines, "\n") <>
          "\n" <>
          dgettext(
            "prompts",
            "Contrasta estas palabras con los hechos y testimonios del resumen. " <>
              "Si ya contestan correctamente lo que te preguntan, basta un acuerdo breve; " <>
              "añade solo lo que falte o corrige una diferencia con lo registrado. " <>
              "No recites de nuevo toda la explicación. Usa una o dos frases cortas."
          )
      end
    else
      ""
    end
  end

  defp response_interventions(_, _), do: ""

  defp response_background(story) when is_binary(story) do
    case story |> String.slice(0, 1800) |> Dragonex.Text.scrub() |> String.trim() do
      "" ->
        ""

      background ->
        "\n" <> dgettext("prompts", "TRASFONDO ACTUAL: %{background}", background: background)
    end
  end

  defp response_background(_), do: ""

  # The combat / exploration instruction for a conscious PC (hp > 0). Extracted
  # from `instruction/3` so the dead/downed branches stay readable.
  defp pc_combat_or_exploration_instruction(c, world) do
    weapons = c.weapons |> Enum.map(& &1.name) |> Enum.join(", ")
    spells = if c.spells == [], do: [], else: c.spells |> Enum.map(& &1.name) |> Enum.join(", ")

    enemies = living_enemies(world, c)
    combat? = world != nil and world.phase == :combat and enemies != []

    cond_line =
      case Character.condition_names(c) do
        [] ->
          ""

        names ->
          dgettext(
            "prompts",
            "- AVISO: estás %{conditions}. Esto puede afectar a tus tiradas de ataque.",
            conditions: Enum.join(names, ", ")
          ) <> "\n"
      end

    if combat? do
      # Combat with real enemies: list them so the bot never proposes a
      # non-existent target. Tools are the right path here.
      targets = Enum.map_join(enemies, ", ", &"\"#{&1}\"")

      base =
        dgettext(
          "prompts",
          "Es TU turno (%{name}). Estás en COMBATE. Objetivos VÁLIDOS (único tipo de objetivo que el motor acepta): %{targets}.",
          name: c.name,
          targets: targets
        ) <>
          "\n" <>
          dgettext(
            "prompts",
            "- Atacar: make_attack(\"%{name}\", \"<objetivo de la lista>\", \"<arma>\") — armas: %{weapons}.",
            name: c.name,
            weapons: weapons
          ) <> "\n"

      # D63: casting is blocked while in beast form — do not offer it.
      spell_line =
        if spells != "" and c.wild_shape == nil,
          do:
            dgettext(
              "prompts",
              "- Conjurar: cast_spell(\"%{name}\", \"<hechizo>\", \"<objetivo de la lista>\") — hechizos: %{spells}.",
              name: c.name,
              spells: spells
            ) <>
              "\n" <>
              dgettext(
                "prompts",
                "- Subir hechizo (upcasting): si te quedan casillas de nivel superior, añade cast_level — cast_spell(\"%{name}\", \"<hechizo>\", \"<objetivo>\", <nivel>) lanza el hechizo con esa casilla (más daño/curación en los que escalan: fireball, burning hands, magic missile, cure wounds…).",
                name: c.name
              ) <>
              "\n" <>
              dgettext(
                "prompts",
                "- Si conoces Bless, su objetivo es un aliado (puedes ser tú; también un aliado caído no muerto), no un enemigo. Añade additional_targets con los nombres de otros aliados: hasta 3 objetivos en total a nivel 1, uno más por nivel superior. El motor aplica +1d4 a ataques/salvaciones durante 1 minuto de concentración; no calcules el bonus."
              ) <>
              "\n" <>
              dgettext(
                "prompts",
                "- Si conoces Shield of Faith, protege a un aliado con +2 CA durante hasta 10 minutos de concentración. Consume acción adicional y casilla; no acumula con otra copia. No lo confundas con Shield."
              ) <>
              "\n" <>
              dgettext(
                "prompts",
                "- Si conoces Heal, usa cast_spell con heal para curar a un aliado vivo o a ti mismo: 70 PG a nivel 6, +10 por nivel superior; elimina blinded, deafened y diseased. No afecta a constructos ni no-muertos; usa una acción, sin concentración."
              ) <>
              "\n" <>
              dgettext(
                "prompts",
                "- Si conoces Spare the Dying, estabiliza a un aliado vivo a 0 pg con cast_spell: una acción, sin casilla ni curación. No resucita ni afecta a constructos o no-muertos."
              ) <>
              "\n" <>
              dgettext(
                "prompts",
                "- Si conoces False Life, conjúralo solo sobre ti: 1d4+4 PG temporales, +5 por nivel de casilla superior al primero. Duran 1 hora sin concentración y no se acumulan."
              ) <> "\n",
          else: ""

      surge_line =
        if c.class == "fighter" and (c.level || 1) >= 2 and c.action_surge_used != true do
          dgettext(
            "prompts",
            "- Oleada de acción (1/descanso): action_surge(\"%{name}\", \"<objetivo de la lista>\", \"<arma>\", \"normal\") EN EL MISMO turno tras make_attack.",
            name: c.name
          ) <> "\n"
        else
          ""
        end

      flurry_line =
        if c.class == "monk" and (c.level || 1) >= 2 and (c.ki || 0) > 0 do
          dgettext(
            "prompts",
            "- Ráfaga de golpes (1 ki): flurry_of_blows(\"%{name}\", \"<objetivo de la lista>\", \"normal\") — 2 golpes sin armas; el motor gasta 1 ki y resuelve las tiradas.",
            name: c.name
          ) <> "\n"
        else
          ""
        end

      bardic_line =
        if c.class == "bard" and (c.bardic_inspiration_uses || 0) > 0 do
          dgettext(
            "prompts",
            "- Inspiración bárdica: bardic_inspiration(\"%{name}\", \"<aliado o %{name}>\") — gasta 1 uso; el motor aplica el d6 al primer roll del inspirado.",
            name: c.name
          ) <> "\n"
        else
          ""
        end

      turn_undead_line = turn_undead_line(c)
      spiritual_weapon_line = spiritual_weapon_line(c)
      hide_line = cunning_hide_line(c)
      dodge_line = uncanny_dodge_line(c)
      breath_line = breath_line(c)

      base <>
        spell_line <>
        surge_line <>
        flurry_line <>
        bardic_line <>
        turn_undead_line <>
        spiritual_weapon_line <>
        hide_line <>
        dodge_line <>
        breath_line <>
        hunters_mark_line(c, world) <>
        font_of_magic_lines(c, world) <>
        metamagic_line(c) <>
        wild_shape_line(c) <>
        cond_line <>
        dgettext(
          "prompts",
          "Elige UNA acción y llama a la herramienta. Luego reacciona en 1-2 frases. Responde en castellano."
        )
    else
      # Exploration: speak / observe / propose — text-only unless a real check.
      # Table feel: propose and wait. Do not leave, time-skip, or decide for
      # the human (rule 13). The old "elige y ejecuta" copy made bots walk off.
      dgettext("prompts", "Es TU turno (%{name}). NO hay enemigos a la vista.", name: c.name) <>
        "\n" <>
        dgettext(
          "prompts",
          "COMPAÑERO DE MESA (PERSONAJE ACTIVO): propone UNA cosa concreta en 1-2 frases y espera. " <>
            "No dirijas la partida ni decidas el plan del grupo."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "- NO te marches solo, NO cruces puertas/arcos, NO viajes, NO abras lo que un humano acaba de cuestionar."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "- NO hables ni actúes por otros PCs. Pregúntales; no asumas que te siguen."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "- Si un compañero humano acaba de proponer o preguntar, responde en una frase y espera su OK."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "- Si hay un PNJ o una pregunta al mundo, di UNA frase y PARA: el DM responde."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "- Nunca escribas «ya se encamina», «desaparece en», «sin esperar respuesta», «dejando que X le siga»."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "COORDINACIÓN: reacciona a lo que acaban de hacer tus compañeros; no abras un hilo paralelo."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "NUNCA termines sólo con 'espero', 'paso' o 'no hago nada' — debes haber propuesto o hecho un gesto local."
        ) <>
        "\n" <>
        wizard_recovery_line(c) <>
        turn_undead_line(c) <>
        wild_shape_line(c) <>
        expertise_line(c) <>
        dgettext(
          "prompts",
          "Si preguntas explícitamente a otros PCs presentes, usa request_response con recipients y question; " <>
            "cada uno responderá por sí mismo. No encadenes preguntas mientras respondes otra."
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "Para resolver una acción con riesgo real de fallo " <>
            "(forzar una puerta, persuadir a un PNJ, detectar una trampa, etc.): " <>
            "ability_check(\"%{name}\", \"<skill o característica>\", <DC>) — pasa el NOMBRE DE SKILL cuando aplique " <>
            "(\"stealth\", \"persuasion\", \"athletics\"…: el motor suma tu competencia de la ficha) y " <>
            "str/dex/con/int/wis/cha sólo para checks genéricos.",
          name: c.name
        ) <>
        "\n" <>
        dgettext(
          "prompts",
          "Si introducen o revelan algo duradero (un PNJ llega, un descubrimiento, un encargo), el DM lo registrará " <>
            "con establish_fact; tú NO necesitas llamarlo. " <>
            "NO inventes make_attack contra objetos, PNJ sin hostilidad, o nombres que no estén en el mundo. " <>
            "Si no sabes qué hacer, propone UNA acción concreta EN ESTA ESCENA (hablar, mirar, preguntar) en personaje."
        ) <>
        "\n" <>
        cond_line <>
        dgettext("prompts", "Responde en castellano.")
    end
  end

  defp wizard_recovery_line(%Character{class: "wizard", name: name, arcane_recovery_used: used})
       when used != true do
    dgettext(
      "prompts",
      "- Recuperación arcana (fuera de combate, 1/descanso largo): arcane_recovery(\"%{name}\") — el motor restaura huecos gastados.",
      name: name
    ) <> "\n"
  end

  defp wizard_recovery_line(_), do: ""

  defp turn_undead_line(%Character{class: "cleric", name: name} = c) do
    if (c.level || 1) >= 2 and c.channel_divinity_used != true do
      dgettext(
        "prompts",
        "- Expulsar no-muertos (Canalizar divinidad, 1/descanso): turn_undead(\"%{name}\") — el motor gasta el uso y aplica asustado a no-muertos que fallen.",
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp turn_undead_line(_), do: ""

  # D99: solo si el arma espiritual está activa se ofrece el golpe extra.
  defp spiritual_weapon_line(%Character{name: name} = c) do
    if Enum.any?(c.conditions || [], fn
         %{"condition" => "spiritual_weapon"} -> true
         _ -> false
       end) do
      dgettext(
        "prompts",
        "- Arma espiritual activa (acción adicional): spiritual_weapon_attack(\"%{name}\", \"<objetivo de la lista>\") — el motor resuelve el ataque de conjuro 1d8+mod de fuerza.",
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp spiritual_weapon_line(_), do: ""

  defp hunters_mark_line(%Character{class: "ranger", name: name} = c, %World{} = world) do
    if (c.level || 1) >= 2 and World.has_slot?(world, name, 1) do
      dgettext(
        "prompts",
        "- Marca del cazador (concentración): hunters_mark(\"%{name}\", \"<objetivo de la lista>\") — gasta 1 casilla de nivel 1; el motor suma +1d6 a tus impactos contra la presa.",
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp hunters_mark_line(_, _), do: ""

  # Cunning Action: Hide (D57): rogue L2+ may hide as a bonus action. Never
  # suggest it while already hidden — re-hiding errors.
  defp cunning_hide_line(%Character{class: "rogue", name: name} = c) do
    if (c.level || 1) >= 2 and "hidden" not in Character.condition_names(c) do
      dgettext(
        "prompts",
        "- Esconderse (Astucia de pícaro): cunning_action_hide(\"%{name}\") — el motor tira Sigilo vs la percepción pasiva más alta de los enemigos; éxito → oculto: tu próximo ataque sale con ventaja (y te revela).",
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp cunning_hide_line(_), do: ""

  # Uncanny Dodge (D64): rogue L5+. Suggest arming while not already
  # armed — re-arming errors.
  defp uncanny_dodge_line(%Character{class: "rogue", name: name} = c) do
    if (c.level || 1) >= 5 and c.uncanny_dodge != true do
      dgettext(
        "prompts",
        "- Esquiva asombrosa (pícaro nivel 5+): start_uncanny_dodge(\"%{name}\") — el motor reduce a la mitad el próximo daño que recibas y consume la postura.",
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp uncanny_dodge_line(_), do: ""

  # D70 Breath Weapon: racial (dragonborn), any class/level — suggest the
  # line while the per-rest use lasts.
  defp breath_line(%Character{name: name} = c) do
    if dragonborn_race?(c) and c.breath_weapon_used != true do
      dgettext(
        "prompts",
        "- Aliento de dragón (dragontino, 1/descanso): breath_weapon(\"%{name}\", \"<objetivo de la lista>\") — el motor gasta el uso y resuelve la salvación de DES del objetivo (daño de fuego, mitad si la supera).",
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp breath_line(_), do: ""

  defp dragonborn_race?(%Character{race: race}) when is_binary(race),
    do: String.downcase(race) == "dragonborn"

  defp dragonborn_race?(_), do: false

  # Wild Shape (D63): druid L2+. Suggest transforming while uses remain (and
  # not already in beast form); while transformed, remind that casting is
  # blocked and how to return.
  defp wild_shape_line(%Character{class: "druid", name: name} = c) do
    cond do
      c.wild_shape != nil ->
        dgettext(
          "prompts",
          "- Estás en FORMA SALVAJE: NO puedes conjurar (cast_spell fallará). Para volver: end_wild_shape(\"%{name}\") — el motor restaura tu forma y tus pg originales.",
          name: name
        ) <> "\n"

      (c.level || 1) >= 2 and (c.wild_shape_uses || 0) > 0 ->
        dgettext(
          "prompts",
          "- Forma salvaje (1 uso): wild_shape(\"%{name}\", \"cat\" | \"wolf\" | \"black_bear\" según nivel) — el motor aplica los stats y ataques de la bestia; en forma animal no puedes conjurar.",
          name: name
        ) <> "\n"

      true ->
        ""
    end
  end

  defp wild_shape_line(_), do: ""

  # D73 Expertise: rogue (L1+) / bard (L3+) with picks left — suggest the
  # choice only while the class/level cupo exceeds what's already chosen.
  defp expertise_line(%Character{class: class, name: name} = c)
       when class in ["rogue", "bard"] do
    cap = Progression.expertise_count(c.class, c.level)
    chosen = length(c.expertise || [])

    if cap > chosen do
      dgettext(
        "prompts",
        "- Expertise (duplica tu bonus de competencia en una skill entrenada; " <>
          "elecciones pendientes %{chosen}/%{cap}): " <>
          "gain_expertise(\"%{name}\", \"<skill que ya tengas entrenada>\") — " <>
          "el motor valida clase, nivel, entrenamiento y cupo.",
        chosen: chosen,
        cap: cap,
        name: name
      ) <> "\n"
    else
      ""
    end
  end

  defp expertise_line(_), do: ""

  # Font of Magic (D56): sorcerer L2+ converts points ↔ slots. Create line
  # only when they can pay the cheapest slot (2 points); convert line only
  # when they still hold at least one slot.
  defp font_of_magic_lines(%Character{class: "sorcerer", name: name} = c, %World{} = world) do
    if (c.level || 1) >= 2 do
      create_line =
        if (c.sorcery_points || 0) >= 2 do
          dgettext(
            "prompts",
            "- Crear casilla (Fuente de magia): create_spell_slot(\"%{name}\", <nivel 1-5>) — cuesta 2/3/5/6/7 puntos según nivel; el motor resta los puntos y suma la casilla.",
            name: name
          ) <> "\n"
        else
          ""
        end

      convert_line =
        if slot_count(world, name) > 0 do
          dgettext(
            "prompts",
            "- Convertir casilla (Fuente de magia): convert_to_sorcery_points(\"%{name}\", <nivel 1-5>) — gasta 1 casilla de ese nivel y recupera esos puntos de hechicería (tope nivel).",
            name: name
          ) <> "\n"
        else
          ""
        end

      create_line <> convert_line
    else
      ""
    end
  end

  defp font_of_magic_lines(_, _), do: ""

  defp slot_count(%World{spell_slots: slots}, name) do
    slots |> Map.get(name, %{}) |> Map.values() |> Enum.sum()
  end

  # D65 Metamagic: sorcerer L3+. Suggest arming while unarmed with at
  # least 1 point (cheapest option); when armed, remind that the next
  # qualifying spell applies and consumes it (re-arming errors).
  defp metamagic_line(%Character{class: "sorcerer", name: name} = c) do
    cond do
      (c.level || 1) < 3 ->
        ""

      c.metamagic != nil ->
        dgettext(
          "prompts",
          "- Metamagia ARMADA (%{option}): el motor la aplicará y consumirá con tu próximo hechizo que califique — lanza ya ese hechizo.",
          option: metamagic_option_es(c.metamagic)
        ) <> "\n"

      (c.sorcery_points || 0) >= 1 ->
        dgettext(
          "prompts",
          "- Metamagia (hechicero nivel 3+): arm_metamagic(\"%{name}\", \"empowered\" | \"heightened\" | \"twinned\", objetivo si aplica) — cuesta 1/3/2 puntos; el motor la aplica a tu próximo hechizo que califique (Empowered re-tira dados de daño, Heightened da desventaja a la salvación del objetivo, Twinned golpea también al segundo objetivo).",
          name: name
        ) <> "\n"

      true ->
        ""
    end
  end

  defp metamagic_line(_), do: ""

  defp metamagic_option_es(%{option: opt}), do: metamagic_option_es(opt)

  defp metamagic_option_es("empowered"), do: "Empowered"
  defp metamagic_option_es("heightened"), do: "Heightened"
  defp metamagic_option_es("twinned"), do: "Twinned"
  defp metamagic_option_es(opt), do: opt

  # The valid attack/cast targets for this PC: every living character on the
  # other side. Returns [] when world is nil (defensive — keep old behaviour).
  defp living_enemies(nil, _c), do: []

  defp living_enemies(%World{} = world, %Character{side: side}) do
    World.present_characters(world)
    |> Map.values()
    |> Enum.filter(fn ch -> ch.side != side and (ch.hp || 0) > 0 end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  # --- personality by class ---

  defp personality(%Character{class: c, backstory: story}) do
    class_trait = class_personality(c)

    parts =
      [
        dgettext("prompts", "PERSONALIDAD: %{trait}", trait: class_trait),
        if(story && story != "",
          do: dgettext("prompts", "TRASFONDO: %{story}", story: story),
          else: nil
        )
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n")
  end

  defp class_personality("barbarian"),
    do:
      dgettext(
        "prompts",
        "Eres fiero, primitivo y te enfadas con facilidad. Cargas al combate con un rugido, confías en tus instintos y resuelves los problemas con fuerza bruta. Eres ferozmente leal a tus aliados."
      )

  defp class_personality("bard"),
    do:
      dgettext(
        "prompts",
        "Eres carismático, creativo y siempre tienes una frase o una canción a punto. Encantas en las situaciones sociales e inspiras a tus aliados con palabras y música."
      )

  defp class_personality("cleric"),
    do:
      dgettext(
        "prompts",
        "Eres devoto, compasivo y te guía la fe. Curas a los heridos, proteges a los inocentes y hablas con la autoridad serena de quien sirve a un poder superior."
      )

  defp class_personality("druid"),
    do:
      dgettext(
        "prompts",
        "Eres sabio, sintonizado con la naturaleza y protector de lo salvaje. Prefieres las formas antiguas y te comunicas con los espíritus del bosque, tomando forma bestial cuando hace falta."
      )

  defp class_personality("fighter"),
    do:
      dgettext(
        "prompts",
        "Eres disciplinado, táctico y maestro de las armas. Afrontas el peligro de frente, entrenado para el combate, y proteges a tus aliados con pericia marcial."
      )

  defp class_personality("monk"),
    do:
      dgettext(
        "prompts",
        "Eres sereno, disciplinado y canalizas la energía interior. Unes cuerpo y mente: fluyes en combate con puños y técnica depurada, ajeno a la provocación."
      )

  defp class_personality("paladin"),
    do:
      dgettext(
        "prompts",
        "Eres honorable, justo y estás vinculado por un juramento sagrado. Luchas por la justicia, proteges a los débiles y preferirías morir antes que romper tu palabra. Tu convicción es tu fuerza."
      )

  defp class_personality("ranger"),
    do:
      dgettext(
        "prompts",
        "Eres paciente, observador y te sientes en casa en la naturaleza. Rastreas a tu presa, golpeas a distancia y confías en la tierra. Eres autosuficiente y práctico."
      )

  defp class_personality("rogue"),
    do:
      dgettext(
        "prompts",
        "Eres astuto, sigiloso y oportunista. Buscas el ángulo, aprovechas los puntos débiles y golpeas cuando llega el momento. Tienes la lengua afilada y los reflejos aún más."
      )

  defp class_personality("sorcerer"),
    do:
      dgettext(
        "prompts",
        "Eres seguro, intuitivo y desbordas poder crudo. La magia fluye por ti de forma natural — no la estudias, la sientes. Eres audaz y a veces temerario."
      )

  defp class_personality("warlock"),
    do:
      dgettext(
        "prompts",
        "Eres ambicioso, misterioso y estás atado por un pacto con un poder más allá del entendimiento mortal. Buscas conocimiento y ventaja, y tu magia tiene un precio que aceptas de buen grado."
      )

  defp class_personality("wizard"),
    do:
      dgettext(
        "prompts",
        "Eres curioso, metódico y estás fascinado sin fin por la magia. Afrontas los problemas de forma analítica, valoras el conocimiento por encima de todo y siempre tienes el hechizo adecuado para la situación."
      )

  defp class_personality(_),
    do: dgettext("prompts", "Eres un aventurero capaz con tus propias motivaciones y estilo.")

  defp gear_line(%Character{weapons: w, spells: s}) do
    weapon_str = w |> Enum.map(&"#{&1.name} (#{&1.dice} #{&1.damage_type})") |> Enum.join(", ")

    spell_str =
      if s == [] do
        ""
      else
        spells =
          s
          |> Enum.map(&"#{&1.name} (#{spell_level_label(&1.level)})")
          |> Enum.join(", ")

        "\n" <> dgettext("prompts", "- Hechizos conocidos: %{spells}.", spells: spells)
      end

    dgettext("prompts", "- Armas: %{weapons}.", weapons: weapon_str) <> spell_str
  end

  defp spell_level_label(0), do: dgettext("prompts", "truco")
  defp spell_level_label(level), do: dgettext("prompts", "nivel %{level}", level: level)

  # Localized race/class labels for the opening identity line, in lower case
  # because they sit mid-sentence ("un humano clérigo"). Unknown keys fall back
  # to the stored value.
  defp race_label(nil), do: dgettext("prompts", "aventurero")
  defp race_label(race), do: race |> Translations.race_display(I18n.locale()) |> String.downcase()

  defp class_label(nil), do: dgettext("prompts", "aventurero")
  defp class_label(class), do: class |> Translations.class(I18n.locale()) |> String.downcase()
end
