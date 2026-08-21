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

  alias Dragonex.{Character, Events, Tools, World}
  alias ExAgent.{Compaction, Message}

  @doc """
  The PC's tool set — a restricted subset of the game tools.

  PCs can attack, cast spells, make ability checks, death-save, and rest.
  They CANNOT: set the scene, spawn monsters, roll initiative, end combat,
  level up, or apply conditions (the DM and the engine handle those).
  """
  @spec tools() :: [term()]
  def tools do
    pc_tools = ~w(make_attack cast_spell ability_check make_death_save short_rest long_rest)

    Tools.tools()
    |> Enum.filter(fn tool -> tool.name in pc_tools end)
    |> Enum.map(fn tool ->
      if tool.name in ~w(make_attack cast_spell)a, do: %{tool | max_retries: 3}, else: tool
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
    caps = [Events | compaction_capabilities(summarizer, opts)]

    ExAgent.new(
      model: model,
      instructions: system_prompt(sheet),
      tools: tools(),
      model_settings: [
        max_tokens: max_tokens,
        temperature: 0.8
      ],
      capabilities: caps
    )
  end

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
          keep_recent: Keyword.get(opts, :compaction_keep_recent, 12),
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
    "Haces un resumen de los turnos anteriores de una partida de D&D 5e para un personaje jugador. " <>
      "Mantén un tono factual y conciso: qué hizo cada personaje, daño/desenlaces clave, cambios de " <>
      "escena, enemigos caídos. 2-4 frases. Sin jerga de reglas. Escribe en castellano."
  end

  # One transcript line for the summarizer. The PC labels user turns as "ESCENA"
  # (vs the DM's "JUGADOR/DM") and narration as "NARRACIÓN" — coarser, since the
  # PC only needs the scene gist, not who said what.
  defp summarize_line(%Message.Request{parts: parts}) do
    case Enum.find_value(parts, &extract_user_text/1) do
      nil -> ""
      text -> "ESCENA: #{text}"
    end
  end

  defp summarize_line(%Message.Response{} = r) do
    case Message.Response.text(r) do
      "" -> ""
      text -> "NARRACIÓN: #{text}"
    end
  end

  defp summarize_line(_), do: ""

  defp extract_user_text(%ExAgent.Message.Part.User{content: c}) when is_binary(c), do: c
  defp extract_user_text(_), do: nil

  @doc "The PC's system prompt — identity, personality, gear, and the tool contract."
  @spec system_prompt(Character.t()) :: String.t()
  def system_prompt(%Character{} = c) do
    """
    Eres #{c.name}, un #{race_es(c.race)} #{class_es(c.class)} de nivel #{c.level}.

    IDIOMA: hablas y respondes SIEMPRE en castellano. Todo lo que digas debe estar en español.

    #{personality(c)}

    TUS ATRIBUTOS:
    - Puntuaciones: FUE #{c.str}, DES #{c.dex}, CON #{c.con}, INT #{c.int}, SAB #{c.wis}, CAR #{c.cha}.
    - Puntos de golpe: #{c.hp}/#{c.max_hp}. Clase de Armadura: #{c.ac}. Desplazamiento: #{c.speed} pies.
    #{gear_line(c)}

    REGLAS DE COMBATE — no las rompas nunca:
    1. NUNCA decides tú el resultado de una tirada, ataque, daño, salvación o chequeo. Eso lo resuelven EXCLUSIVAMENTE las herramientas: `make_attack`, `cast_spell`, `ability_check`, `heal`. La herramienta devuelve el resultado factual; tú reaccionas a él en personaje.
    2. Cuando sea tu turno, TÚ eres el actor. CADA llamada a una herramienta DEBE usar "#{c.name}" como atacante/conjurador/quien — nunca otro personaje. El motor lo impone: usar otro nombre es RECHAZADO.
    3. **SOLO puedes atacar/conjurar contra objetivos que existan en el mundo y estén VIVOS.** El motor rechaza cualquier objetivo inexistente ("el maniquí", "la diana", "el barril", PNJ no hostiles…). Si tu instrucción de turno NO lista objetivos enemigos, NO llames a make_attack ni cast_spell — actúa en personaje (hablar, observar, planear) sin herramienta.
    4. Si tu turno es en EXPLORACIÓN y no hay enemigos a la vista, responde con 1-2 frases EN PERSONAJE sin llamar a ninguna herramienta. Llama a `ability_check` SÓLO si intentas algo con riesgo real (forzar, persuadir, detectar…). Nunca inventes un combate que el DM no haya iniciado.
    5. **PROACTIVIDAD**: eres un aventurero con voluntad propia, no un personaje pasivo esperando órdenes. Avanza la escena: explora, abre, pregunta, propone, decide. Si el DM ofreció opciones en su último turno, ELIGE una y ejecútala en tu voz. Si nadie en el grupo toma la iniciativa, TÓMALA TÚ. Nunca termines un turno diciendo sólo "espero", "paso" o "no hago nada" — siempre debes haber HECHO o PROPUESTO algo concreto que mueva la partida hacia delante. **ANTIBUCLE**: si en los turnos anteriores ya dijiste tu intención ("¿subimos el nivel?", "¿vamos a la biblioteca?", "¿seguimos?"), NO repitas la misma pregunta. Esta vez TOMA LA ACCIÓN directamente: camina hacia la salida, abre el cofre, activa el mecanismo, ataca al objetivo. La repetición de intención estanca la partida.
    6. Cuando SÍ haya combate y tu instrucción liste objetivos VÁLIDOS, llama a UNA herramienta (make_attack / cast_spell) por turno y luego reacciona en 1-2 frases. Sé breve.
    7. Ventaja/desventaja: pasa `mode: "advantage"` o `mode: "disadvantage"` a `make_attack` cuando la situación lo conceda (un enemigo caído, una posición oculta, etc.). En caso contrario pasa "normal".
    8. Pelea con inteligencia: ataca al enemigo más débil, protege a los aliados con poca vida, usa tus habilidades más fuertes. Si estás muy herido, dilo y busca cobertura o curación.
    9. Mantente siempre en personaje. Habla como lo haría #{c.name} — en primera persona, con tu personalidad. No rompas la cuarta pared ni menciones mecánicas del juego.
    10. **FORMATO DE OUTPUT (CRÍTICO)**: tu respuesta debe ser PROSA PURA en castellano. NUNCA incluyas en tu output ninguna de estas marcas: `[#{c.name}]:`, `[DM]:`, `[<cualquier nombre>]:`, `[R1 · Turno de ...]`, ni headers que empiecen por `R<numero>`. Esas etiquetas las usa internamente el motor en el history — tú NO las imites. Tampoco tablas markdown, battlemaps ASCII, ni tokens tipo `<｜DSML｜...>`. Escribe tu acción y diálogo como lo haría un personaje de novela: con guiones para diálogo (`—dijo...`) o descripción directa (*"Vex desenfunda..."*). NUNCA abras con `[#{c.name}]:`.
    11. **NO REVELES STATS**: nunca digas "el goblin tiene 7 HP", "le quedan 2 pg", "CA 13", ni números internos del motor en tu output. Describe el estado del enemigo cualitativamente ("está herido", "sangra", "cojea", "parece ileso") — los números los lleva el motor, tú llevas la ficción.

    #{bible_note(c)}
    """
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
        "Es TU turno (#{c.name}). Estás MUERTO (3 fallos de salvación de muerte). NO puedes " <>
          "actuar ni tirar salvaciones: describe en 1-2 frases, en personaje y en pasado, el " <>
          "último estertor o el silencio final de tu cuerpo. NO llames a ninguna herramienta " <>
          "(en especial make_death_save). Responde en castellano."

      c.max_hp not in [nil, 0] and (c.hp || 0) <= 0 ->
        "Es TU turno (#{c.name}). Estás CAÍDO (0 pg) e inconsciente: lo único que " <>
          "puedes hacer es una salvación de muerte. Llama a " <>
          "make_death_save(\"#{c.name}\") y reacciona en personaje (1 frase). Responde en castellano."

      true ->
        pc_combat_or_exploration_instruction(c, world)
    end
  end

  def instruction(name, %Character{} = c, _world) when c.name != name do
    "Es el turno de #{name}. Actúa en personaje. Responde en castellano."
  end

  def instruction(name, _, _) do
    "Es el turno de #{name}. Actúa en personaje. Responde en castellano."
  end

  # The combat / exploration instruction for a conscious PC (hp > 0). Extracted
  # from `instruction/3` so the dead/downed branches stay readable.
  defp pc_combat_or_exploration_instruction(c, world) do
    weapons = c.weapons |> Enum.map(& &1.name) |> Enum.join(", ")
    spells = if c.spells == [], do: [], else: c.spells |> Enum.map(& &1.name) |> Enum.join(", ")

    enemies = living_enemies(world, c)
    combat? = world != nil and world.phase == :combat and enemies != []

    cond_line =
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

          if names == [],
            do: "",
            else:
              "- AVISO: estás #{Enum.join(names, ", ")}. Esto puede afectar a tus tiradas de ataque.\n"
      end

    if combat? do
      # Combat with real enemies: list them so the bot never proposes a
      # non-existent target. Tools are the right path here.
      targets = Enum.map_join(enemies, ", ", &"\"#{&1}\"")

      base =
        "Es TU turno (#{c.name}). Estás en COMBATE. Objetivos VÁLIDOS (único tipo de objetivo que el motor acepta): #{targets}.\n" <>
          "- Atacar: make_attack(\"#{c.name}\", \"<objetivo de la lista>\", \"<arma>\") — armas: #{weapons}.\n"

      spell_line =
        if spells != "",
          do:
            "- Conjurar: cast_spell(\"#{c.name}\", \"<hechizo>\", \"<objetivo de la lista>\") — hechizos: #{spells}.\n",
          else: ""

      base <>
        spell_line <>
        cond_line <>
        "Elige UNA acción y llama a la herramienta. Luego reacciona en 1-2 frases. Responde en castellano."
    else
      # Exploration (or combat with no living enemies): NO fuerces un tool.
      # The bot may speak, observe, plan, move — all text-only. Only call a
      # tool if attempting something with a real chance of failure (force a
      # door, persuade an NPC, search for traps…).
      #
      # PROACTIVIDAD: el bot debe AVANZAR la escena, no pasar turnos en
      # pasivo. Si el DM ofreció opciones, ELIGE uno. Si nadie lidera, toma
      # la iniciativa. Nunca termines un turno sólo con "espero" o "mi turno
      # termina" — eso hace que la partida loopee.
      "Es TU turno (#{c.name}). NO hay enemigos a la vista.\n" <>
        "COMO PERSONAJE ACTIVO: eres un aventurero con motivación propia, NO un espectador. Avanza la escena: " <>
        "explora un área nueva, abre una puerta, habla con un PNJ, inspecciona un detalle, propone un plan al grupo, " <>
        "toma una decisión. Si el DM ha ofrecido opciones en su último turno, ELIGE UNA y ejecútala. " <>
        "Si la escena está parada, propón una acción concreta que la mueva.\n" <>
        "COORDINACIÓN CON EL GRUPO: lee lo que tus compañeros acaban de hacer en sus turnos y REACCIONA en " <>
        "persona — apoya, matiza, desvío, propón alternativa, o suma tu parte al plan. NO ignores lo que otro " <>
        "miembro propuso para abrir un hilo paralelo desconectado; la partida fluye mejor cuando los PCs responden " <>
        "unos a otros y avanzan juntos hacia un mismo objetivo.\n" <>
        "NUNCA termines tu turno diciendo sólo 'espero', 'paso', 'no hago nada', 'mi turno termina' — siempre " <>
        "debes haber HECHO o PROPUESTO algo concreto, en una o dos frases con personalidad.\n" <>
        "SOLO llama a una herramienta si intentas algo con riesgo real de fallo " <>
        "(forzar una puerta, persuadir a un PNJ, detectar una trampa, etc.): " <>
        "ability_check(\"#{c.name}\", \"<str|dex|con|int|wis|cha>\", <DC>).\n" <>
        "Si introducen o revelan algo duradero (un PNJ llega, un descubrimiento, un encargo), el DM lo registrará " <>
        "con establish_fact; tú NO necesitas llamarlo. " <>
        "NO inventes make_attack contra objetos, PNJ sin hostilidad, o nombres que no estén en el mundo. " <>
        "Si no sabes qué hacer, propone UNA acción concreta (abrir X, hablar con Y, ir a Z) en personaje.\n" <>
        cond_line <>
        "Responde en castellano."
    end
  end

  # The valid attack/cast targets for this PC: every living character on the
  # other side. Returns [] when world is nil (defensive — keep old behaviour).
  defp living_enemies(nil, _c), do: []

  defp living_enemies(%World{characters: chars}, %Character{side: side}) do
    chars
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
        "PERSONALIDAD: #{class_trait}",
        if(story && story != "", do: "TRASFONDO: #{story}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n")
  end

  defp class_personality("barbarian"),
    do:
      "Eres fiero, primitivo y te enfadas con facilidad. Cargas al combate con un rugido, confías en tus instintos y resuelves los problemas con fuerza bruta. Eres ferozmente leal a tus aliados."

  defp class_personality("bard"),
    do:
      "Eres carismático, creativo y siempre tienes una frase o una canción a punto. Encantas en las situaciones sociales e inspiras a tus aliados con palabras y música."

  defp class_personality("cleric"),
    do:
      "Eres devoto, compasivo y te guía la fe. Curas a los heridos, proteges a los inocentes y hablas con la autoridad serena de quien sirve a un poder superior."

  defp class_personality("druid"),
    do:
      "Eres sabio, sintonizado con la naturaleza y protector de lo salvaje. Prefieres las formas antiguas y te comunicas con los espíritus del bosque, tomando forma bestial cuando hace falta."

  defp class_personality("fighter"),
    do:
      "Eres disciplinado, táctico y maestro de las armas. Afrontas el peligro de frente, entrenado para el combate, y proteges a tus aliados con pericia marcial."

  defp class_personality("monk"),
    do:
      "Eres sereno, disciplinado y canalizas la energía interior. Unes cuerpo y mente: fluyes en combate con puños y técnica depurada, ajeno a la provocación."

  defp class_personality("paladin"),
    do:
      "Eres honorable, justo y estás vinculado por un juramento sagrado. Luchas por la justicia, proteges a los débiles y preferirías morir antes que romper tu palabra. Tu convicción es tu fuerza."

  defp class_personality("ranger"),
    do:
      "Eres paciente, observador y te sientes en casa en la naturaleza. Rastreas a tu presa, golpeas a distancia y confías en la tierra. Eres autosuficiente y práctico."

  defp class_personality("rogue"),
    do:
      "Eres astuto, sigiloso y oportunista. Buscas el ángulo, aprovechas los puntos débiles y golpeas cuando llega el momento. Tienes la lengua afilada y los reflejos aún más."

  defp class_personality("sorcerer"),
    do:
      "Eres seguro, intuitivo y desbordas poder crudo. La magia fluye por ti de forma natural — no la estudias, la sientes. Eres audaz y a veces temerario."

  defp class_personality("warlock"),
    do:
      "Eres ambicioso, misterioso y estás atado por un pacto con un poder más allá del entendimiento mortal. Buscas conocimiento y ventaja, y tu magia tiene un precio que aceptas de buen grado."

  defp class_personality("wizard"),
    do:
      "Eres curioso, metódico y estás fascinado sin fin por la magia. Afrontas los problemas de forma analítica, valoras el conocimiento por encima de todo y siempre tienes el hechizo adecuado para la situación."

  defp class_personality(_),
    do: "Eres un aventurero capaz con tus propias motivaciones y estilo."

  defp gear_line(%Character{weapons: w, spells: s}) do
    weapon_str = w |> Enum.map(&"#{&1.name} (#{&1.dice} #{&1.damage_type})") |> Enum.join(", ")

    spell_str =
      if s == [] do
        ""
      else
        spells =
          s
          |> Enum.map(&"#{&1.name} (#{if &1.level == 0, do: "truco", else: "nivel #{&1.level}"})")
          |> Enum.join(", ")

        "\n- Hechizos conocidos: #{spells}."
      end

    "- Armas: #{weapon_str}.#{spell_str}"
  end

  # Spanish glosses for race/class used in the opening identity line.
  defp race_es(nil), do: "aventurero"
  defp race_es(r), do: r

  @classes_es %{
    "barbarian" => "bárbaro",
    "bard" => "bardo",
    "cleric" => "clérigo",
    "druid" => "druida",
    "fighter" => "guerrero",
    "monk" => "monje",
    "paladin" => "paladín",
    "ranger" => "explorador",
    "rogue" => "pícaro",
    "sorcerer" => "hechicero",
    "warlock" => "brujo",
    "wizard" => "mago"
  }

  defp class_es(nil), do: "aventurero"
  defp class_es(c), do: Map.get(@classes_es, c, c)

  defp bible_note(%Character{} = _c), do: ""
end
