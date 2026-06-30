defmodule Dragones.Game.Instructions do
  @moduledoc """
  The per-turn instruction strings stitched onto a beat's prompt.

  An instruction tells the acting agent what to do this turn — the base text the
  guardrails (`Dragones.Game.Guardrails`) amend. These are pure string builders,
  extracted from `Dragones.Game` so the prompt copy lives apart from the
  turn-loop orchestration.
  """

  @doc """
  The instruction for a human-controlled participant proposing an action: it
  directs the model to resolve the declared text by the rules, acting AS that
  participant (never a monster — the control guard would reject it).
  """
  @spec human_instruction(String.t(), String.t()) :: String.t()
  def human_instruction(name, text),
    do:
      "Es el turno de #{name}. Estás proponiendo COMO #{name}: en CADA llamada a una herramienta " <>
        "el atacante/conjurador/quien DEBE ser \"#{name}\" (nunca un monstruo — que un monstruo actúe " <>
        "ahora es RECHAZADO). #{name} (un personaje jugador) declara: \"#{if text == "", do: "(pasa)", else: text}\". " <>
        "Resuélvelo por las reglas (llama a la herramienta adecuada con \"#{name}\" como actor) y luego narra. Responde en castellano."

  @doc "The default DM instruction for its turn."
  @spec dm_instruction() :: String.t()
  def dm_instruction,
    do:
      "Actúa por cualquier monstruo/PNJ cuyo turno sea. " <>
        "Si los jugadores han pedido algo concreto (combate, explorar, hablar con un PNJ), " <>
        "EJECÚTALO ahora: usa spawn_monster si piden pelea, narra lo que encuentran si exploran, " <>
        "responde si preguntan. NO narres que un PNJ 'espera' o 'no responde' — haz que ACTÚE. " <>
        "Si la escena lleva parada más de un turno, introduce algo NUEVO (enemigo, evento, revelación). " <>
        "NO repitas la misma descripción de escena. Narra en 1-3 frases y responde en castellano."

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
      "⚠️ AVANCE OBLIGATORIO ⚠️ El combate acaba de terminar y la partida está ATASCADA " <>
        "pidiendo a los jugadores '¿qué hacéis?' en bucle. ESTE TURNO DEBES AVANZAR LA " <>
        "ESCENA, NO abrir la pregunta al grupo. Elige UNA de estas opciones y EJECÚTALA:\n" <>
        "1. spawn_monster(\"<kind>\", \"<name>\") — una nueva oleada/hostil aparece (si la biblia " <>
        "lo permite: goblin, kobold, skeleton, orc, wolf, training_dummy...).\n" <>
        "2. Un PNJ llega con noticias o un nuevo encargo (narrado + diálogo del PNJ).\n" <>
        "3. set_scene(\"<nueva localización o situación>\") — la party es trasladada a otra " <>
        "zona (biblioteca, taberna, mazmorra, lo que dicte la biblia).\n" <>
        "4. Un evento ambiental: la puerta cede, suena una alarma, llega el anochecer...\n\n" <>
        "NUNCA termines este turno con '¿qué hacéis?' o '¿qué deseáis hacer?'. " <>
        "Sé BREVE (2-4 frases): describe el nuevo elemento y TERMINA. Los PCs reaccionarán " <>
        "en sus turnos. Responde en castellano."

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
      "⚠️ AVANCE OBLIGATORIO ⚠️ La escena lleva VARIOS turnos sin progreso: todo el grupo " <>
        "narra y re-declara intenciones ('¿empezamos con X?', '¿vamos a Y?') pero NADIE actúa. " <>
        "ESTE TURNO DEBES ROMPER EL STATU QUO y mover la partida. NO abras con '¿qué hacéis?'. " <>
        "Elige UNA opción y EJECÚTALA:\n" <>
        "1. spawn_monster(\"<kind>\", \"<name>\") — una amenaza irrumpe y FUERZA el combate " <>
        "(goblin, kobold, skeleton, orc, wolf… lo que dicte la biblia).\n" <>
        "2. Un PNJ llega o reacciona con información/urgencia que exija respuesta inmediata.\n" <>
        "3. set_scene(\"<nueva localización o situación>\") — traslada al grupo a otra zona.\n" <>
        "4. Un evento ambiental que cambie las condiciones (la puerta cede, suena una alarma, " <>
        "cruje el suelo, se apagan las antorchas…).\n" <>
        "5. Si un PC pidió algo concreto en su último turno, RESUÉLVELO ahora (ability_check, " <>
        "lo que encuentran al investigar, la respuesta del PNJ).\n\n" <>
        "Sé BREVE (2-3 frases): introduce el cambio y TERMINA. Los PCs reaccionarán después. " <>
        "Responde en castellano."
end
