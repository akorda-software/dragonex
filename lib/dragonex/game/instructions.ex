defmodule Dragonex.Game.Instructions do
  @moduledoc """
  The per-turn instruction strings stitched onto a beat's prompt.

  An instruction tells the acting agent what to do this turn — the base text the
  guardrails (`Dragonex.Game.Guardrails`) amend. These are pure string builders,
  extracted from `Dragonex.Game` so the prompt copy lives apart from the
  turn-loop orchestration.
  """

  use Gettext, backend: Dragonex.Gettext

  @doc """
  The instruction for a human-controlled participant proposing an action: it
  directs the model to resolve the declared text by the rules, acting AS that
  participant (never a monster — the control guard would reject it).
  """
  @spec human_instruction(String.t(), String.t()) :: String.t()
  @spec human_instruction(String.t(), String.t(), map() | nil) :: String.t()
  def human_instruction(name, text, conversation \\ nil),
    do:
      dgettext(
        "prompts",
        "Es el turno de %{name}. Estás resolviendo SOLO lo que %{name} acaba de declarar, actuando COMO %{name}. " <>
          "En CADA herramienta el atacante/conjurador/quien DEBE ser \"%{name}\" (nunca un monstruo — RECHAZADO). " <>
          "%{name} declara: \"%{text}\". " <>
          "Resuelve solo las reglas declaradas mediante las herramientas necesarias. " <>
          "Si el objetivo declarado aún no tiene ficha en el estado, no lo crees ni lo ataques: " <>
          "cierra con la confirmación; el DM lo registrará y abrirá la iniciativa. " <>
          "La voz de %{name} la publica el motor desde su declaración literal; termina con una confirmación breve. " <>
          "NO añadas palabras, decisiones, gestos ni consecuencias a la declaración de %{name}. " <>
          "NO hables ni actúes por otros PCs (ni diálogo, ni gestos, ni que te sigan). " <>
          "NO des voz a PNJs: si %{name} les habla, termina cuando %{name} termina de hablar — el DM responde.",
        name: name,
        text: if(text == "", do: dgettext("prompts", "(pasa)"), else: text)
      ) <>
        " " <>
        human_question_instruction(name, conversation) <>
        dgettext(
          "prompts",
          "NO saltes el tiempo ni cambies de lugar (nada de 'media hora después', caminatas, llegadas, set_scene): " <>
            "quédate aquí. El viaje y la respuesta del mundo los narra el DM. " <>
            "Responde en castellano."
        )

  defp human_question_instruction(name, %{"from" => from, "world_recipient" => recipient})
       when name == from do
    dgettext(
      "prompts",
      "Pregunta ya registrada por el motor para %{recipient}; el DM responderá. " <>
        "No llames request_response ni sustituyas la pregunta. Narra solo la pregunta de %{name}.",
      recipient: recipient,
      name: name
    ) <> " "
  end

  defp human_question_instruction(name, %{"from" => from, "recipients" => recipients})
       when name == from do
    dgettext(
      "prompts",
      "Pregunta ya registrada por el motor para %{recipients}. " <>
        "No vuelvas a llamar request_response ni sustituyas la pregunta. " <>
        "Narra solo la pregunta de %{name}; cada compañero responderá en su propio turno.",
      recipients: Enum.join(recipients, ", "),
      name: name
    ) <> " "
  end

  defp human_question_instruction(name, _) do
    dgettext(
      "prompts",
      "En EXPLORACIÓN, si la declaración PREGUNTA explícitamente a otros PCs presentes, llama " <>
        "request_response con recipients (nombres canónicos, en el orden pedido) y question (la pregunta real). " <>
        "Narra solo la pregunta de %{name}; cada compañero responderá en su propio turno. " <>
        "No llames request_response por una mera mención, por PNJs, ni en combate.",
      name: name
    ) <> " "
  end

  @doc "Inventory confirmation belongs to the exploration DM beat, including after human narration."
  def inventory_instruction(world, actor, events \\ [])

  def inventory_instruction(%{phase: :exploration}, "dm", events) do
    "\n\n" <>
      dgettext(
        "prompts",
        "CONSISTENCIA DE INVENTARIO: este es TU turno DM. El Inventario del resumen " <>
          "es el stock real; que el narrador del turno humano diga 'lo guarda' o 'lo deja' " <>
          "no lo registra. TU responsabilidad incluye confirmar y registrar las consecuencias " <>
          "físicas de esa acción, aunque el narrador ya las haya descrito. No te limites a " <>
          "comentarla como PNJ. Revisa la acción y la respuesta del mundo: si confirmas una recogida o entrega " <>
          "a un PC que aún no está registrada, llama grant_item ANTES de narrarla. Una devolución " <>
          "de PNJ a la mano del PC también es una entrega. Si confirmas que deja o entrega un " <>
          "objeto poseído, llama remove_item, incluso si solo lo deja sobre una piedra junto a él. " <>
          "Usa nombres/cantidades reales del resumen. No dupliques lo ya registrado ni conviertas " <>
          "una petición pendiente en posesión. Si una entrega confirmada cumple un encargo de los " <>
          "hechos, regístralo como cerrado con establish_fact para que no se reintroduzca."
      ) <>
      recent_inventory_action(events)
  end

  def inventory_instruction(%{phase: :exploration}, actor, _events) do
    "\n\n" <>
      dgettext(
        "prompts",
        "Este es el turno de %{actor}: grant_item y remove_item pertenecen al posterior " <>
          "turno DM y el motor los rechazará aquí. Narra la intención de recoger o entregar " <>
          "sin confirmar que cambió la posesión; esa respuesta del mundo corresponde al DM.",
        actor: actor
      )
  end

  def inventory_instruction(_, _, _), do: ""

  @doc "Canonical surroundings and discoveries are confirmed by the DM, even after human resolution."
  def fact_instruction(%{phase: :exploration}, "dm") do
    "\n\n" <>
      dgettext(
        "prompts",
        "MEMORIA DE DESCUBRIMIENTOS: este es TU turno DM. Que el narrador humano " <>
          "describa una pista o un hallazgo no lo registra ni lo confirma en el mundo. " <>
          "Revisa la declaración, el resultado real y los hechos del resumen; decide la respuesta del mundo. " <>
          "Una tirada exitosa no demuestra por sí sola quién dejó una huella, la identidad de un objeto " <>
          "ni la verdad de un rumor. Si confirmas un descubrimiento concreto y duradero que importa " <>
          "recordar y aún no está registrado, llama establish_fact ANTES de narrarlo; " <>
          "actualiza el entorno confirmado con set_scene si quedó antiguo. No dupliques hechos " <>
          "ni registres cada gesto o detalle pasajero. No conviertas intenciones, propuestas " <>
          "o afirmaciones de PCs en verdad por el mero hecho de estar narradas. Para lo que " <>
          "un PNJ afirma, usa record_npc_statement con su fuente y dudas, sin confirmarlo. " <>
          "No inventes acciones de PCs para registrar un hecho; describe el mundo ya confirmado."
      )
  end

  def fact_instruction(%{phase: :exploration}, actor) do
    "\n\n" <>
      dgettext(
        "prompts",
        "Este es el turno de %{actor}: establish_fact y set_scene pertenecen al " <>
          "posterior turno DM y el motor las rechaza si intentas usar esas herramientas aquí. " <>
          "Resuelve solo tus reglas y narra tu intención u observación, sin confirmar por tu " <>
          "cuenta hechos nuevos del mundo. La respuesta y el registro canónico corresponden al DM.",
        actor: actor
      )
  end

  def fact_instruction(_, _), do: ""

  @doc "Keep secondhand claims attributed even after earlier prose or a summary overstates them."
  def testimony_instruction(world, actor) do
    if Enum.any?(world.facts, &Dragonex.NPCStatement.attributed?/1) do
      "\n\n" <>
        dgettext(
          "prompts",
          "FUENTES Y CERTEZA: usa las secciones actuales de hechos y testimonios " <>
            "para distinguir lo confirmado de lo que cada fuente afirma. La prosa anterior " <>
            "y los resúmenes pueden confundir esas fuentes; no convierten un testimonio en prueba " <>
            "ni en un recuerdo visual del grupo. Conserva la fuente y sus dudas también al resumirlo. " <>
            "Si una entrada posterior aclara de dónde salió un detalle o limita lo que esa fuente vio, " <>
            "conserva esa aclaración al usarlo; no mezcles la versión anterior con ella como una " <>
            "observación independiente. La entrada posterior sigue siendo un testimonio y no anula " <>
            "automáticamente otras afirmaciones de esa fuente o de otras fuentes."
        ) <>
        " " <>
        testimony_voice(actor)
    else
      ""
    end
  end

  defp testimony_voice("dm") do
    dgettext(
      "prompts",
      "Si una comparación o detalle procede solo de un testimonio, atribúyelo a su fuente " <>
        "sin presentarlo como observación de los PCs. Puedes usar 'lo vi' en la voz del PNJ " <>
        "que afirma haberlo visto; eso sigue siendo su afirmación, no una confirmación del mundo."
    )
  end

  defp testimony_voice(actor) do
    dgettext(
      "prompts",
      "Responde como %{actor}. Si una comparación o detalle procede solo de un testimonio, " <>
        "di 'según' su fuente, en lugar de 'lo vi', 'lo vimos' o 'con nuestros propios ojos'. " <>
        "Distingue lo que encontrasteis de lo que os contaron; no inventes una observación " <>
        "para respaldar una conclusión ni elimines la incertidumbre de la fuente.",
      actor: actor
    )
  end

  defp recent_inventory_action(events) do
    recent = events |> Enum.reverse() |> Enum.filter(&(Map.get(&1, :visible_to) in ["all", "dm"]))
    action = Enum.find(recent, &(&1.type == :action))
    previous_dm = Enum.find(recent, &(&1.type == :narration and &1.actor == "dm"))

    if action && (is_nil(previous_dm) || action.seq > previous_dm.seq) do
      text = action.payload["text"] || ""

      "\n" <>
        dgettext(
          "prompts",
          "Última declaración pendiente de consecuencias del mundo — %{actor}:",
          actor: action.actor
        ) <>
        " " <>
        Dragonex.Text.scrub(String.slice(text, 0, 1800), action.actor)
    else
      ""
    end
  end

  def dm_conversation_instruction(%{"from" => from, "world_recipient" => recipient} = request) do
    dgettext(
      "prompts",
      "%{from} preguntó a %{recipient}: %{question}. " <>
        "Responde como ese PNJ en 1-3 frases con información concreta del mundo. " <>
        "Si aportas información duradera del PNJ, usa record_npc_statement antes de narrarla: conserva quién lo afirma, sus dudas y de quién lo supo. " <>
        "No conviertas una versión o rumor en hecho confirmado ni inventes certezas para llenar la respuesta. " <>
        "No hables por PCs ni decidas sus acciones. El jugador espera aquí tu respuesta; " <>
        "no ha decidido viajar ni ejecutar otro plan. Conserva esta escena y responde en castellano.",
      from: from,
      recipient: recipient,
      question: request["question"]
    )
  end

  def dm_conversation_instruction(request) do
    dgettext(
      "prompts",
      "%{from} preguntó a sus compañeros: %{question}. " <>
        "Las intervenciones ya están en el historial con su propia voz; si alguien no pudo responder, no inventes su respuesta. " <>
        "Una conversación entre PCs no es un atasco ni exige novedades. El motor devolverá la palabra a %{from}. " <>
        "No recapitules sus respuestas ni repitas la descripción del ambiente. " <>
        "Narra una consecuencia concreta si realmente la hay, o responde si un PNJ también recibió una pregunta. " <>
        "Si nada más necesita respuesta, basta una frase breve que deje abierta la decisión del jugador. " <>
        "No añadas gestos PNJ, utensilios, sonidos, luces u hora del día solo para decorar el cierre. " <>
        "No abras otra pregunta al grupo. No respondas por PCs ni inventes sus gestos. " <>
        "No conviertas una petición de opinión en viaje, combate o gasto de magia. " <>
        "El jugador aún no ha decidido partir ni ejecutar un plan. Mantén esta escena y responde en castellano.",
      from: request["from"],
      question: request["question"]
    )
  end

  @doc "The default DM instruction for its turn. Names the live combat slot when set (D34)."
  @spec dm_instruction() :: String.t()
  @spec dm_instruction(String.t() | nil) :: String.t()
  def dm_instruction(combatant \\ nil)

  def dm_instruction(combatant) when is_binary(combatant) and combatant != "" do
    dgettext(
      "prompts",
      "Actúa SOLO por %{combatant} (su slot de iniciativa). No narres ni ataques con otros monstruos este beat.",
      combatant: combatant
    ) <>
      " " <>
      dm_instruction_tail()
  end

  def dm_instruction(_),
    do:
      dgettext("prompts", "Actúa por cualquier monstruo/PNJ cuyo turno sea.") <>
        " " <>
        dm_instruction_tail()

  @doc """
  Pending-intent note for the DM beat that follows a human turn whose declaration
  was published without any engine roll (e.g. an attack on a creature that had
  no sheet yet). Inventory and questions are excluded: the DM confirms
  possession and answers. Empty when the previous actor turn rolled, was not a
  human declaration, or another actor acted in between.
  """
  def unresolved_human_intent(events) when is_list(events) do
    case previous_actor_turn(events) do
      %{actor: actor, payload: %{"turn_id" => turn_id}} when actor != "dm" ->
        same_turn = Enum.filter(events, &(&1.payload["turn_id"] == turn_id))

        voice =
          Enum.find(
            same_turn,
            &(&1.type == :narration and &1.payload["kind"] == "human_declaration")
          )

        if voice && not Enum.any?(same_turn, &(&1.type == :dice)) do
          "\n\n" <>
            dgettext(
              "prompts",
              "INTENCIÓN PENDIENTE: La declaración de %{actor} no aplicó reglas ni tiradas del motor " <>
                "(«%{text}»). Si era un ataque, conjuro o prueba, no narres su resultado " <>
                "como ocurrido (impacto, fallo, daño): pertenece al turno de %{actor}. Prepara la situación " <>
                "con las herramientas que te correspondan.",
              actor: actor,
              text: voice.payload["text"]
            )
        else
          ""
        end

      _ ->
        ""
    end
  end

  # The actor turn before the DM's current one (the last :turn start is the DM's).
  defp previous_actor_turn(events) do
    events
    |> Enum.filter(&(&1.type == :turn and &1.payload["kind"] in ["start", :start]))
    |> Enum.reverse()
    |> case do
      [%{actor: "dm"}, previous | _] -> previous
      _ -> nil
    end
  end

  @doc "Pacing for a timed wait recognized by the engine, rather than an exploration stall."
  def dm_wait_instruction do
    dgettext(
      "prompts",
      "ESPERA DELIBERADA: resuelve la espera que el jugador ya declaró, aquí y por su duración real. " <>
        "Esperar deliberadamente es una decisión, no un atasco. Puede mantenerse el ambiente sin añadir novedades. " <>
        "No cierres investigaciones ni retires PNJs fuera de escena solo para hacer avanzar la trama. " <>
        "No inventes horas transcurridas, cierres de lugares o viajes por el mero paso de este intervalo. " <>
        "El reloj es relativo y no determina la hora del día. Conserva la hora narrativa ya establecida. " <>
        "La espera no garantiza tranquilidad: un suceso coherente con la campaña puede interrumpirla; " <>
        "registra solo el tiempo realmente transcurrido y describe esa interrupción."
    ) <>
      " " <>
      dm_agency_instruction() <>
      " " <> dgettext("prompts", "Narra en 1-3 frases y responde en castellano.")
  end

  defp dm_instruction_tail,
    do:
      dgettext(
        "prompts",
        "Si los jugadores han pedido algo concreto (combate, explorar, hablar con un PNJ), " <>
          "EJECÚTALO ahora: usa spawn_monster si piden pelea, narra lo que encuentran si exploran, " <>
          "responde si preguntan. NO narres que un PNJ 'espera' o 'no responde' — haz que ACTÚE. " <>
          "Si la escena lleva parada más de un turno, introduce algo NUEVO (enemigo, evento, revelación). " <>
          "NO repitas la misma descripción de escena."
      ) <>
        " " <>
        dm_agency_instruction() <>
        " " <> dgettext("prompts", "Narra en 1-3 frases y responde en castellano.")

  defp dm_agency_instruction do
    dgettext(
      "prompts",
      "Respeta el estilo de partida también al introducir eventos. " <>
        "No decidas acciones ni traslados de los PCs: una propuesta de un compañero no es una decisión del grupo. " <>
        "No des por tomado un acuerdo entre los PCs: si el humano espera respuestas antes de decidir, devuélvele la decisión. " <>
        "Cuando actualices el entorno o reveles un detalle, no los muevas ni les impongas un plan."
    )
  end

  @doc """
  Special DM instruction fired when we detect post-combate limbo — combate
  ended but the timeline hasn't moved past it. The DM is FORCED to advance:
  invoke a new threat, change scene, introduce a PNJ with news. The "¿qué
  hacéis?" open question is explicitly banned here because that's exactly
  what creates the loop where every PC re-declares "seguimos con lo siguiente".
  """
  @spec dm_post_combat_instruction() :: String.t()
  def dm_post_combat_instruction,
    do:
      dgettext(
        "prompts",
        "⚠️ AVANCE OBLIGATORIO ⚠️ El combate acaba de terminar y la partida está ATASCADA " <>
          "pidiendo a los jugadores '¿qué hacéis?' en bucle. ESTE TURNO DEBES AVANZAR LA " <>
          "ESCENA, NO abrir la pregunta al grupo. Elige UNA de estas opciones y EJECÚTALA:\n" <>
          "1. spawn_monster(\"<kind>\", \"<name>\") — una nueva oleada/hostil aparece (si la biblia " <>
          "lo permite: goblin, kobold, skeleton, orc, wolf, training_dummy...).\n" <>
          "2. Un PNJ llega con noticias o un nuevo encargo (narrado + diálogo del PNJ).\n" <>
          "3. set_scene(\"<situación actualizada>\") — describe un cambio del entorno o una " <>
          "localización ya decidida por los PCs; no los traslades por tu cuenta.\n" <>
          "4. Un evento ambiental: la puerta cede, suena una alarma, llega el anochecer...\n\n" <>
          "NUNCA termines este turno con '¿qué hacéis?' o '¿qué deseáis hacer?'."
      ) <>
        " " <>
        dm_agency_instruction() <>
        "\n" <>
        dgettext(
          "prompts",
          "Sé BREVE (2-4 frases): describe el nuevo elemento y TERMINA. Los PCs reaccionarán " <>
            "en sus turnos. Responde en castellano."
        )

  @doc """
  Exploration-stall avance: the partida has been cycling through pure narration
  with nobody acting (no checks, no spawns, no scene changes). The DM is forced
  to break the statu quo itself rather than re-asking "¿qué hacéis?". Similar
  in spirit to the post-combate instruction but pitched for a stalled
  exploration scene.
  """
  @spec dm_advance_instruction() :: String.t()
  def dm_advance_instruction,
    do:
      dgettext(
        "prompts",
        "⚠️ AVANCE OBLIGATORIO ⚠️ La escena lleva VARIOS turnos sin progreso: todo el grupo " <>
          "narra y re-declara intenciones ('¿empezamos con X?', '¿vamos a Y?') pero NADIE actúa. " <>
          "ESTE TURNO DEBES ROMPER EL STATU QUO y mover la partida. NO abras con '¿qué hacéis?'. " <>
          "Elige UNA opción y EJECÚTALA:\n" <>
          "1. spawn_monster(\"<kind>\", \"<name>\") — una amenaza irrumpe y FUERZA el combate " <>
          "(goblin, kobold, skeleton, orc, wolf… lo que dicte la biblia).\n" <>
          "2. Un PNJ llega o reacciona con información/urgencia que exija respuesta inmediata.\n" <>
          "3. set_scene(\"<situación actualizada>\") — describe un cambio del entorno o una " <>
          "localización ya decidida por los PCs; no los traslades por tu cuenta.\n" <>
          "4. Un evento ambiental que cambie las condiciones (la puerta cede, suena una alarma, " <>
          "cruje el suelo, se apagan las antorchas…).\n" <>
          "5. Si un PC pidió algo concreto en su último turno, RESUÉLVELO ahora (ability_check, " <>
          "lo que encuentran al investigar, la respuesta del PNJ)."
      ) <>
        "\n\n" <>
        dm_agency_instruction() <>
        "\n" <>
        dgettext(
          "prompts",
          "Sé BREVE (2-3 frases): introduce el cambio y TERMINA. Los PCs reaccionarán después. " <>
            "Responde en castellano."
        )
end
