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
  (rogue L5+), and transform themselves with Wild Shape
  (druid L2+: `wild_shape` / `end_wild_shape`).
  They CANNOT:
  set the scene, spawn monsters, roll initiative, end combat, level up, or
  apply conditions (the DM and the engine handle those).
  """
  @spec tools() :: [term()]
  def tools do
    pc_tools =
      ~w(make_attack cast_spell ability_check make_death_save short_rest long_rest drop_concentration start_rage end_rage start_reckless end_reckless second_wind action_surge flurry_of_blows hunters_mark cunning_action_hide start_uncanny_dodge create_spell_slot convert_to_sorcery_points arm_metamagic divine_smite end_smite lay_on_hands divine_sense turn_undead bardic_inspiration arcane_recovery wild_shape end_wild_shape)

    Tools.tools()
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
    5. **MESA, NO SOLILOQUIO**: eres un compañero de mesa, no el director. En exploración, PROPÓN una acción concreta en 1-2 frases y ESPERA al grupo y al DM. No te marches solo, no cruces umbrales, no viajes, no ejecutes un plan de varios pasos, no decidas por un PC humano. Puedes hablar con un PNJ UNA frase y parar: el DM responde. Nunca termines un turno diciendo sólo "espero", "paso" o "no hago nada" — hay que haber propuesto o hecho un gesto local. **ANTIBUCLE**: si ya propusiste lo mismo, no lo reformules; cambia de ángulo EN ESTA ESCENA (un detalle, un gesto, una frase nueva). Nunca "camina hacia la salida", "desaparece en el arco" ni "sin esperar respuesta".
     6. Cuando SÍ haya combate y tu instrucción liste objetivos VÁLIDOS, llama a UNA herramienta (make_attack / cast_spell) por turno y luego reacciona en 1-2 frases. Sé breve. Oleada de acción (guerrero nivel 2+): puedes llamar `action_surge("#{c.name}", objetivo, arma, mode)` EN EL MISMO turno tras `make_attack` — 1 Acción de Ataque extra, 1/descanso.
      7. Ventaja/desventaja: pasa `mode: "advantage"` o `mode: "disadvantage"` a `make_attack` cuando la situación lo conceda (un enemigo caído, una posición oculta, etc.). En caso contrario pasa "normal". Reckless Attack (bárbaro): llama `start_reckless("#{c.name}")`; el motor aplica la ventaja — no pases mode por Reckless. Segundo aliento (guerrero): llama `second_wind("#{c.name}")` — 1d10+nivel, 1/descanso. Oleada de acción (guerrero nivel 2+): `action_surge("#{c.name}", objetivo, arma, mode)` en el mismo turno tras atacar. Ráfaga de golpes (monje nivel 2+): `flurry_of_blows("#{c.name}", objetivo, mode)` — gasta 1 ki; el motor resuelve 2 golpes sin armas. Fuente de magia (hechicero nivel 2+): `create_spell_slot("#{c.name}", nivel)` convierte puntos de hechicería en 1 casilla (nivel 1–5, cuesta 2/3/5/6/7) y `convert_to_sorcery_points("#{c.name}", nivel)` drena 1 casilla (nivel 1–5) y recupera esos puntos (tope nivel); el motor valida, gasta y convierte. Metamagia (hechicero nivel 3+): `arm_metamagic("#{c.name}", "empowered"|"heightened"|"twinned", objetivo_para_heightened/twinned o "")` — gasta 1/3/2 puntos de hechicería y arma UNA opción que el motor aplica y consume con tu próximo hechizo que califique (Empowered re-tira dados de daño; Heightened da desventaja a la salvación del objetivo armado; Twinned golpea también al segundo objetivo armado). Castigo divino (paladín): llama `divine_smite("#{c.name}", nivel_casilla)` antes del ataque melee; el motor aplica el daño radiante al impactar. Manos impositoras (paladín): `lay_on_hands("#{c.name}", objetivo, cantidad)` — cura a un aliado o a ti mismo gastando el pool (5×nivel); el motor aplica y gasta. Sentido divino (paladín): llama `divine_sense("#{c.name}")` — el motor gasta 1 uso y reporta celestiales, infernales y no-muertos. Expulsar no-muertos (clérigo nivel 2+): llama `turn_undead("#{c.name}")` — el motor gasta Canalizar divinidad y aplica asustado a no-muertos que fallen la salvación. Inspiración bárdica (bardo): `bardic_inspiration("#{c.name}", objetivo)` — gasta 1 uso; el motor suma 1d6 al primer ataque, chequeo, salvación o salvación de muerte del inspirado. Recuperación arcana (mago): llama `arcane_recovery("#{c.name}")` fuera de combate — el motor restaura huecos gastados, 1/descanso largo. Marca del cazador (explorador nivel 2+): `hunters_mark("#{c.name}", presa)` — gasta 1 casilla de nivel 1 y concentra; el motor suma +1d6 a tus impactos de arma contra la presa. Astucia de pícaro (pícaro nivel 2+): `cunning_action_hide("#{c.name}")` — el motor tira Sigilo (1d20+DES) contra la percepción pasiva más alta de los enemigos; si superas, quedas oculto: tu próximo ataque sale con ventaja (y te revela). Forma salvaje (druida nivel 2+): `wild_shape("#{c.name}", "cat" | "wolf" | "black_bear")` — gasta 1 uso (2/descanso) y el motor aplica los stats y ataques de la bestia; en forma animal NO puedes conjurar; `end_wild_shape("#{c.name}")` vuelve a tu forma con tus pg originales (si la bestia cae a 0 pg el motor revierte solo). Esquiva asombrosa (pícaro nivel 5+): `start_uncanny_dodge("#{c.name}")` — arma la postura; el motor reduce a la mitad el próximo daño que recibas (de cualquier fuente) y la consume.
    8. Pelea con inteligencia: ataca al enemigo más débil, protege a los aliados con poca vida, usa tus habilidades más fuertes. Si estás muy herido, dilo y busca cobertura o curación.
    9. Mantente siempre en personaje. Habla como lo haría #{c.name} — en primera persona, con tu personalidad. No rompas la cuarta pared ni menciones mecánicas del juego.
    10. **FORMATO DE OUTPUT (CRÍTICO)**: tu respuesta debe ser PROSA PURA en castellano. NUNCA incluyas en tu output ninguna de estas marcas: `[#{c.name}]:`, `[DM]:`, `[<cualquier nombre>]:`, `[R1 · Turno de ...]`, ni headers que empiecen por `R<numero>`. Esas etiquetas las usa internamente el motor en el history — tú NO las imites. Tampoco tablas markdown, battlemaps ASCII, ni tokens tipo `<｜DSML｜...>`. Escribe tu acción y diálogo como un personaje de novela, con guiones (`—dijo...`). SIN asteriscos de markdown (`*se inclina*`). NUNCA abras con `[#{c.name}]:`.
    11. **NO REVELES STATS**: nunca digas "el goblin tiene 7 HP", "le quedan 2 pg", "CA 13", ni números internos del motor en tu output. Describe el estado del enemigo cualitativamente ("está herido", "sangra", "cojea", "parece ileso") — los números los lleva el motor, tú llevas la ficción.
    12. **NO MUEVAS A OTROS PCs**: no narres lo que hace o dice un compañero (humano o bot). Puedes hablarle («¿me cubres?») pero NUNCA escribas que el otro actúa, te sigue o te obedece. El humano decide por sí mismo.
    13. **AQUÍ Y AHORA**: no saltes el tiempo ni cambies de localización (eso es del DM). Actúa en la escena actual. Si hay un humano en el grupo, propone y espera: no decidas el plan por él ni te marches solo.
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
      case Character.condition_names(c) do
        [] ->
          ""

        names ->
          "- AVISO: estás #{Enum.join(names, ", ")}. Esto puede afectar a tus tiradas de ataque.\n"
      end

    if combat? do
      # Combat with real enemies: list them so the bot never proposes a
      # non-existent target. Tools are the right path here.
      targets = Enum.map_join(enemies, ", ", &"\"#{&1}\"")

      base =
        "Es TU turno (#{c.name}). Estás en COMBATE. Objetivos VÁLIDOS (único tipo de objetivo que el motor acepta): #{targets}.\n" <>
          "- Atacar: make_attack(\"#{c.name}\", \"<objetivo de la lista>\", \"<arma>\") — armas: #{weapons}.\n"

      # D63: casting is blocked while in beast form — do not offer it.
      spell_line =
        if spells != "" and c.wild_shape == nil,
          do:
            "- Conjurar: cast_spell(\"#{c.name}\", \"<hechizo>\", \"<objetivo de la lista>\") — hechizos: #{spells}.\n",
          else: ""

      surge_line =
        if c.class == "fighter" and (c.level || 1) >= 2 and c.action_surge_used != true do
          "- Oleada de acción (1/descanso): action_surge(\"#{c.name}\", \"<objetivo de la lista>\", \"<arma>\", \"normal\") EN EL MISMO turno tras make_attack.\n"
        else
          ""
        end

      flurry_line =
        if c.class == "monk" and (c.level || 1) >= 2 and (c.ki || 0) > 0 do
          "- Ráfaga de golpes (1 ki): flurry_of_blows(\"#{c.name}\", \"<objetivo de la lista>\", \"normal\") — 2 golpes sin armas; el motor gasta 1 ki y resuelve las tiradas.\n"
        else
          ""
        end

      bardic_line =
        if c.class == "bard" and (c.bardic_inspiration_uses || 0) > 0 do
          "- Inspiración bárdica: bardic_inspiration(\"#{c.name}\", \"<aliado o #{c.name}>\") — gasta 1 uso; el motor aplica el d6 al primer roll del inspirado.\n"
        else
          ""
        end

      turn_undead_line = turn_undead_line(c)
      hide_line = cunning_hide_line(c)
      dodge_line = uncanny_dodge_line(c)

      base <>
        spell_line <>
        surge_line <>
        flurry_line <>
        bardic_line <>
        turn_undead_line <>
        hide_line <>
        dodge_line <>
        hunters_mark_line(c, world) <>
        font_of_magic_lines(c, world) <>
        metamagic_line(c) <>
        wild_shape_line(c) <>
        cond_line <>
        "Elige UNA acción y llama a la herramienta. Luego reacciona en 1-2 frases. Responde en castellano."
    else
      # Exploration: speak / observe / propose — text-only unless a real check.
      # Table feel: propose and wait. Do not leave, time-skip, or decide for
      # the human (rule 13). The old "elige y ejecuta" copy made bots walk off.
      "Es TU turno (#{c.name}). NO hay enemigos a la vista.\n" <>
        "COMPAÑERO DE MESA (PERSONAJE ACTIVO): propone UNA cosa concreta en 1-2 frases y espera. " <>
        "No dirijas la partida ni decidas el plan del grupo.\n" <>
        "- NO te marches solo, NO cruces puertas/arcos, NO viajes, NO abras lo que un humano acaba de cuestionar.\n" <>
        "- NO hables ni actúes por otros PCs. Pregúntales; no asumas que te siguen.\n" <>
        "- Si un compañero humano acaba de proponer o preguntar, responde en una frase y espera su OK.\n" <>
        "- Si hay un PNJ o una pregunta al mundo, di UNA frase y PARA: el DM responde.\n" <>
        "- Nunca escribas «ya se encamina», «desaparece en», «sin esperar respuesta», «dejando que X le siga».\n" <>
        "COORDINACIÓN: reacciona a lo que acaban de hacer tus compañeros; no abras un hilo paralelo.\n" <>
        "NUNCA termines sólo con 'espero', 'paso' o 'no hago nada' — debes haber propuesto o hecho un gesto local.\n" <>
        wizard_recovery_line(c) <>
        turn_undead_line(c) <>
        wild_shape_line(c) <>
        "SOLO llama a una herramienta si intentas algo con riesgo real de fallo " <>
        "(forzar una puerta, persuadir a un PNJ, detectar una trampa, etc.): " <>
        "ability_check(\"#{c.name}\", \"<skill o característica>\", <DC>) — pasa el NOMBRE DE SKILL cuando aplique " <>
        "(\"stealth\", \"persuasion\", \"athletics\"…: el motor suma tu competencia de la ficha) y " <>
        "str/dex/con/int/wis/cha sólo para checks genéricos.\n" <>
        "Si introducen o revelan algo duradero (un PNJ llega, un descubrimiento, un encargo), el DM lo registrará " <>
        "con establish_fact; tú NO necesitas llamarlo. " <>
        "NO inventes make_attack contra objetos, PNJ sin hostilidad, o nombres que no estén en el mundo. " <>
        "Si no sabes qué hacer, propone UNA acción concreta EN ESTA ESCENA (hablar, mirar, preguntar) en personaje.\n" <>
        cond_line <>
        "Responde en castellano."
    end
  end

  defp wizard_recovery_line(%Character{class: "wizard", name: name, arcane_recovery_used: used})
       when used != true do
    "- Recuperación arcana (fuera de combate, 1/descanso largo): arcane_recovery(\"#{name}\") — el motor restaura huecos gastados.\n"
  end

  defp wizard_recovery_line(_), do: ""

  defp turn_undead_line(%Character{class: "cleric", name: name} = c) do
    if (c.level || 1) >= 2 and c.channel_divinity_used != true do
      "- Expulsar no-muertos (Canalizar divinidad, 1/descanso): turn_undead(\"#{name}\") — el motor gasta el uso y aplica asustado a no-muertos que fallen.\n"
    else
      ""
    end
  end

  defp turn_undead_line(_), do: ""

  defp hunters_mark_line(%Character{class: "ranger", name: name} = c, %World{} = world) do
    if (c.level || 1) >= 2 and World.has_slot?(world, name, 1) do
      "- Marca del cazador (concentración): hunters_mark(\"#{name}\", \"<objetivo de la lista>\") — gasta 1 casilla de nivel 1; el motor suma +1d6 a tus impactos contra la presa.\n"
    else
      ""
    end
  end

  defp hunters_mark_line(_, _), do: ""

  # Cunning Action: Hide (D57): rogue L2+ may hide as a bonus action. Never
  # suggest it while already hidden — re-hiding errors.
  defp cunning_hide_line(%Character{class: "rogue", name: name} = c) do
    if (c.level || 1) >= 2 and "hidden" not in Character.condition_names(c) do
      "- Esconderse (Astucia de pícaro): cunning_action_hide(\"#{name}\") — el motor tira Sigilo vs la percepción pasiva más alta de los enemigos; éxito → oculto: tu próximo ataque sale con ventaja (y te revela).\n"
    else
      ""
    end
  end

  defp cunning_hide_line(_), do: ""

  # Uncanny Dodge (D64): rogue L5+. Suggest arming while not already
  # armed — re-arming errors.
  defp uncanny_dodge_line(%Character{class: "rogue", name: name} = c) do
    if (c.level || 1) >= 5 and c.uncanny_dodge != true do
      "- Esquiva asombrosa (pícaro nivel 5+): start_uncanny_dodge(\"#{name}\") — el motor reduce a la mitad el próximo daño que recibas y consume la postura.\n"
    else
      ""
    end
  end

  defp uncanny_dodge_line(_), do: ""

  # Wild Shape (D63): druid L2+. Suggest transforming while uses remain (and
  # not already in beast form); while transformed, remind that casting is
  # blocked and how to return.
  defp wild_shape_line(%Character{class: "druid", name: name} = c) do
    cond do
      c.wild_shape != nil ->
        "- Estás en FORMA SALVAJE: NO puedes conjurar (cast_spell fallará). Para volver: end_wild_shape(\"#{name}\") — el motor restaura tu forma y tus pg originales.\n"

      (c.level || 1) >= 2 and (c.wild_shape_uses || 0) > 0 ->
        "- Forma salvaje (1 uso): wild_shape(\"#{name}\", \"cat\" | \"wolf\" | \"black_bear\" según nivel) — el motor aplica los stats y ataques de la bestia; en forma animal no puedes conjurar.\n"

      true ->
        ""
    end
  end

  defp wild_shape_line(_), do: ""

  # Font of Magic (D56): sorcerer L2+ converts points ↔ slots. Create line
  # only when they can pay the cheapest slot (2 points); convert line only
  # when they still hold at least one slot.
  defp font_of_magic_lines(%Character{class: "sorcerer", name: name} = c, %World{} = world) do
    if (c.level || 1) >= 2 do
      create_line =
        if (c.sorcery_points || 0) >= 2 do
          "- Crear casilla (Fuente de magia): create_spell_slot(\"#{name}\", <nivel 1-5>) — cuesta 2/3/5/6/7 puntos según nivel; el motor resta los puntos y suma la casilla.\n"
        else
          ""
        end

      convert_line =
        if slot_count(world, name) > 0 do
          "- Convertir casilla (Fuente de magia): convert_to_sorcery_points(\"#{name}\", <nivel 1-5>) — gasta 1 casilla de ese nivel y recupera esos puntos de hechicería (tope nivel).\n"
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
        "- Metamagia ARMADA (#{metamagic_option_es(c.metamagic)}): el motor la aplicará y consumirá con tu próximo hechizo que califique — lanza ya ese hechizo.\n"

      (c.sorcery_points || 0) >= 1 ->
        "- Metamagia (hechicero nivel 3+): arm_metamagic(\"#{name}\", \"empowered\" | \"heightened\" | \"twinned\", objetivo si aplica) — cuesta 1/3/2 puntos; el motor la aplica a tu próximo hechizo que califique (Empowered re-tira dados de daño, Heightened da desventaja a la salvación del objetivo, Twinned golpea también al segundo objetivo).\n"

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
end
