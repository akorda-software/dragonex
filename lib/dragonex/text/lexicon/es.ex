defmodule Dragonex.Text.Lexicon.Es do
  @moduledoc """
  Castilian vocabulary of `Dragonex.Text`, moved verbatim from the original
  module. Spanish behaviour must stay byte-identical: change these patterns
  only together with the Spanish `test/dragonex/text_*_test.exs` suites.
  """

  # ---------------------------------------------------------------- scrub

  @doc "Spanish questions open with `¿`; the question parsers depend on it."
  def inverted_questions?, do: true

  @doc "Spanish punctuation closes outside the quotation (`«Esperad».`): no extra boundary."
  def closed_quote_boundary, do: nil

  # Roll-card words a glued actor name can fuse with ("Lyrachequeo").
  def fused_roll_words, do: "chequeo|ataque|tirada|salvaci[oó]n"

  # Inline HP/CA leaks. Conservative on bare numbers: a digit only counts as
  # HP when followed explicitly by pg/hp/p.g./puntos de (golpe|vida). "CA" is
  # matched case-sensitively so the syllable "ca" inside other words is safe.
  @inline_hp_xy ~r/\b\d{1,4}\s*\/\s*\d{1,4}\s*(?:pg|hp|p\.g\.|puntos de (?:golpe|vida))\b/i
  @inline_bare_hp ~r/\b(?:\d{1,4}\s*(?:pg|hp|p\.g\.)|(?:pg|hp)\s*\d{1,4})\b/i
  @inline_puntos ~r/\b\d{1,4}\s*puntos de (?:golpe|vida)\b/i
  @inline_of_total ~r/\b\d{1,4}\s*de los\s*\d{1,4}\s*puntos de (?:golpe|vida)(?:\s*originales)?\b/i
  @inline_ca ~r/\b(?:CA|AC)\s*(?::|=|es|de)?\s*\d{1,4}\b/
  @inline_ca_long ~r/\bclase de armadura\s*(?::|=|es|de)?\s*\d{1,4}\b/i
  @stats_parens ~r/\([^)]*(?:\b(?:CA|AC|HP|PG|pg)\b\s*(?:[:=]|\s*es\s*|\s*de\s*)?\s*\d|\d{1,4}\s*\/\s*\d{1,4})[^)]*\)/i
  @hp_left ~r/\ble quedan\b\s*\/?\s*(?:pg|hp)?\.?/i

  def inline_hp_xy, do: @inline_hp_xy
  def inline_bare_hp, do: @inline_bare_hp
  def inline_points, do: @inline_puntos
  def inline_of_total, do: @inline_of_total
  def inline_ac, do: @inline_ca
  def inline_ac_long, do: @inline_ca_long
  def stats_parens, do: @stats_parens
  def hp_left, do: @hp_left

  # Leftovers after stripping the unit: orphan "N de" and dangling
  # "queda con ." / "cae a ," / "recuperado por completo .".
  @orphan_of ~r/\b\d{1,4}\s+de\s*(?:\*\*)?\s*(?=\*\*|[.,;:!?…]|$)/u
  @dangling_stat ~r/\b(queda con|cae a|baja a|tiene|con|por completo)\s*(?=[.,;!?…]|$)/iu

  def orphan_of, do: @orphan_of
  def dangling_stat, do: @dangling_stat

  @tool_leak_words ~r/\b(?:ataque|ataca|chequeo|tirada|da[nñ]o|salvaci[oó]n|iniciativa)\b/i
  def tool_leak_words, do: @tool_leak_words

  @recap_headers ~r/^\s*\*{0,2}\s*(?:Estado del (?:Combate|Batalla)|Situación(?: actual)?|Resumen(?: del combate)?|Combate|Stats?|Batalla)\s*\*{0,2}\s*[:：]\s*\*{0,2}\s*$/i
  @recap_row_hp ~r/\d{1,4}\s*\/\s*\d{1,4}\s*(?:pg|hp)/i
  @recap_row_ac ~r/\bCA\s*\d+/i

  def recap_headers, do: @recap_headers
  def recap_row_hp, do: @recap_row_hp
  def recap_row_ac, do: @recap_row_ac

  # Engine meta phrases and DM fourth-wall breaks, applied in order.
  @engine_meta [
    ~r/el (?:sistema|motor|framework|backend)\s+(?:resuelve|decide|procesa|devuelve)[^.]*\./i,
    ~r/la (?:herramienta|tool|función)\s+(?:resuelve|devuelve|procesa)[^.]*\./i,
    ~r/la escena se resetea[^.]*\./i,
    ~r/\blo materializo(?:\s+en el mundo)?[^.]*\./i,
    ~r/para que (?:sea oficial|conste|quede registrado)[^.]*\./i,
    ~r/(?:yo )?como DM[^.]*\./i,
    ~r/\b[Ee]l [ée]xito del (?:chequeo|estudio|examen)[^.]*\./u,
    # The engine's own turn cue ("Es TU turno (DM)") echoed back as prose.
    ~r/[^.!?]*\bturno\s*\(\s*DM\s*\)[^.!?]*[.!?]*\s*/iu
  ]

  def engine_meta, do: @engine_meta

  @narrated_tool_brackets ~r/\[(?:establecer )?(?:hecho|spawn|invocaci[oó]n|narraci[oó]n|acci[oó]n)\s*[:=][^\]]*\]/i
  def narrated_tool_brackets, do: @narrated_tool_brackets

  # ------------------------------------------------------------- puppeting

  @puppet_action_verbs ~w(
    ataca ataco atacar ataque
    lanza lanzo lanzar
    conjura conjuro conjurar
    golpea golpeo golpear
    dispara disparo disparar
    desenvaina desenvainar desenfunda desenfundar
    tensa tensar apunta apuntar
    prepara preparar
    carga cargo cargar
    salta salto saltar
    corre correr
    persigue perseguir
    hechiza hechizar
    arremete arremeter
    embiste embestir
    invoca invocar
    avanza avanzar cruza cruzar
    sube subir baja bajar
    entra entrar sale salir
    mueve mover
    abre abrir cierra cerrar
    empuja empujar tira tirar
    agarra coge toma deja
    gira voltea
    examina examinar inspecciona inspeccionar
    busca buscar registra estudia
    dice hablar habla
    asiente asentir
    grita susurrar susurra
    pregunta preguntar responde responder exclama replica
    aprovecha aprovechar
    se_abalanza se_lanza se_agacha se_acerca se_incorpora se_prepara
  )

  # All proactive verbs are matched as the PC's immediate predicate (with
  # an optional apposition), so a passive PC state cannot borrow a later
  # NPC's action. The live gesture regression also covers "sigue hojeando".
  @puppet_direct_verbs ~w(alza afina comenta hojea recoge recoger)

  # A clitic can precede the PC's immediate predicate: the real closing used
  # "Iria las recoge ... asintiendo". Keep this bounded to one indirect/reflexive
  # and one object pronoun, rather than borrowing any later verb in the clause.
  @puppet_clitics "(?:(?:me|te|se|nos|os|le|les)\\s+)?(?:(?:lo|la|los|las)\\s+)?"

  @puppet_verb_alt @puppet_action_verbs
                   |> Enum.map(fn v ->
                     v |> String.replace("_", "\\s+") |> then(&"(?:#{&1})")
                   end)
                   |> Enum.join("|")
  @puppet_direct_action "(?:#{Enum.join(@puppet_direct_verbs, "|")}|sigue\\s+hojeando)"
  @puppet_action "(?:#{@puppet_verb_alt}|#{@puppet_direct_action})"
  @puppet_qualified_action "(?:ya\\s+)?#{@puppet_clitics}#{@puppet_action}"

  @doc "Regex source of a PC's proactive predicate (optional `ya` + clitics + verb)."
  def puppet_qualified_action, do: @puppet_qualified_action

  @doc "Relative pronoun introducing a PC's relative action (`Lyra, que …`)."
  def relative_pronoun, do: "que"

  @doc "Temporal subordinators introducing a PC's subordinate action."
  def subordinators, do: "(?:cuando|mientras)"

  # Preserve a separately stated environmental subject after a removed PC
  # action. These are scene nouns, not a general Spanish subject parser; a
  # coordinated object ("y las guarda") still belongs to the removed action.
  @pc_environment_tail ~r/,\s+(?:y|e)\s+(?=(?:el|la|los|las|un|una|unos|unas)\s+(?:aire|luz|calor|frío|brisa|viento|lluvia|fuego|pájaro|arrendajo|roble|puerta|ventana|sala|mesa)\b)/iu
  def pc_environment_tail, do: @pc_environment_tail

  # Explicit party subjects and committed plural movement borrow every PC's
  # decision. Keep the vocabulary bounded: passive consequences, qualified NPC
  # groups, questions and conditional invitations remain outside these cuts.
  @collective_patterns [
    ~r/^\s*(?:—\s*)?(?:el grupo|la party|el equipo|la compañía)\s+(?:ya\s+)?(?:cruza|avanza|parte|sale|entra|decide|acepta|camina|se\s+(?:acerca|dirige|marcha|adentra))\b/iu,
    ~r/^\s*(?:—\s*)?(?:los aventureros|las aventureras)\s+(?:ya\s+)?(?:cruzan|avanzan|parten|salen|entran|deciden|aceptan|caminan|se\s+(?:acercan|dirigen|marchan|adentran))\b/iu,
    ~r/^\s*(?:—\s*)?(?:vosotr[oa]s\s+)?(?:os\s+(?:acercáis|dirigís|marcháis|adentráis)|decidís|cruzáis|avanzáis|salís|entráis|aceptáis|partís|seguís|camináis)\b/iu,
    ~r/^\s*(?:—\s*)?(?:nosotr[oa]s\s+)?(?:nos\s+(?:acercamos|dirigimos|marchamos|adentramos)|decidimos|cruzamos|avanzamos|salimos|entramos|aceptamos|partimos|seguimos|caminamos)\b/iu,
    ~r/^\s*(?:—\s*)?la\s+decisión\s+(?:ya\s+)?(?:queda|está|ha\s+quedado)\s+(?:ya\s+)?tomada\s+entre\s+vosotr[oa]s\b/iu
  ]

  def collective_patterns, do: @collective_patterns

  @collective_heads [
    "el grupo",
    "la party",
    "el equipo",
    "la compañía",
    "la decisión",
    "los aventureros",
    "las aventureras",
    "vosotros",
    "vosotras",
    "nosotros",
    "nosotras",
    "os",
    "nos",
    "decidís",
    "cruzáis",
    "avanzáis",
    "salís",
    "entráis",
    "aceptáis",
    "partís",
    "seguís",
    "camináis",
    "decidimos",
    "cruzamos",
    "avanzamos",
    "salimos",
    "entramos",
    "aceptamos",
    "partimos",
    "seguimos",
    "caminamos",
    "al"
  ]

  def collective_heads, do: @collective_heads

  # The real opening also assumed movement inside an otherwise valid NPC
  # description: "y al acercaros el destello se revela". Cut only the bounded
  # temporal trigger/destination; questions, plans and quoted NPC speech stay.
  @implicit_party_movement ~r/\bal\s+(?:acercar|adentrar|dirigir|marchar|alejar|apartar)(?:os|nos)\b(?:\s+(?:a|al|hacia|hasta|en|de|del|dentro\s+de|fuera\s+de)\b[^,;.!?…:«»“"\n]{0,120}(?:,|(?=[;.!?…:«»“"\n]|$)))?\s*/iu
  # The granero closing also borrowed a collective decision and a coordinated
  # "y os miráis un momento" inside the human's otherwise valid declaration.
  @implicit_party_gesture ~r/(?:,\s*)?(?:\b(?:y|e)\s+)?\b(?:os\s+miráis|nos\s+miramos)\b(?:\s+(?:un\s+momento|unos\s+instantes|en\s+silencio|entre\s+vosotr[oa]s))?/iu
  @implicit_party_plan ~r/\b(?:si|podría(?:s|is|mos|n)?|puede(?:s|n)?|podéis|podemos|propongo|proponemos|sugiero|sugerimos)\b/iu
  @implicit_lead ~r/^\s*al\s+/iu
  @trailing_conj ~r/\s+(?:y|e|pero|mientras|cuando|luego)\s*$/iu

  def implicit_party_movement, do: @implicit_party_movement
  def implicit_party_gesture, do: @implicit_party_gesture
  def implicit_party_plan, do: @implicit_party_plan
  def implicit_lead, do: @implicit_lead
  def trailing_conj, do: @trailing_conj

  @speech_attribution ~r/^\s*[,—-]?\s*(?:dice|pregunta|responde|añade|replica|exclama|susurra|grita|murmura|comenta)\s+/iu

  def speech_attribution, do: @speech_attribution

  @doc "Spanish attributes speech verb-first; there is no name-first form to parse."
  def speech_attribution_name_first, do: nil

  # ------------------------------------------------------ PC world leaks

  @time_skips [
    ~r/\b(?:media hora|un rato|unos minutos|unas horas|varios d[ií]as|un par de horas)\s+despu[eé]s\b/iu,
    ~r/\b(?:horas?|d[ií]as?|minutos?)\s+m[aá]s tarde\b/iu,
    ~r/\bal cabo de\s+(?:un rato|una hora|unas horas|unos minutos)\b/iu,
    ~r/\bal (?:d[ií]a|amanecer|anochecer) siguiente\b/iu
  ]

  def time_skips, do: @time_skips

  @npc_speech_verbs ~r/\b(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|grita|gritando|susurra|chilla|maldice)\b/iu
  @npc_attr ~r/\b(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|grita|gritando|susurra)\s+(?:el|la|los|las)\s+(\w+)/iu
  @npc_role_name ~r/^(?:posadero|posadera|tabernero|tabernera|mesonero|encargado|encapuchado|emisario|anciano|anciana|enano|enana)\b/iu
  @npc_named ~r/\b(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|grita|gritando|susurra)\s+([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)/u
  @npc_name_speaks ~r/\b([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)\s+(?:dice|responde|pregunta|exclama|replica|gru[nñ]e|a[nñ]ade|contin[uú]a|baja la voz|grita|gritando|susurra|maldice)\s*:/u
  @npc_voice_colon ~r/\b(?:baja la voz|dice con voz|contesta|replica en voz|grita|gritando|chilla|a[uú]lla|maldice|susurra|vocifera)\s*:/iu
  # A role recipient is not the speaker: "—digo a la posadera—." closes the
  # PC's own dialogue. Require a separate role subject/label at a clause or
  # coordination boundary before attributing the following quotation to it.
  @npc_role_speaks ~r/(?:^|[,;:]\s*|\b(?:y|e|pero|mientras|cuando)\s+)(?:el|la)\s+(?:posadero|posadera|tabernero|tabernera|mesonero|encargado|encapuchado|emisario|anciano|anciana|enano|enana)\b.{0,120}[—«"“]/iu
  @npc_role_relative_speaks ~r/\b(?:el|la|al|del)\s+(?:posadero|posadera|tabernero|tabernera|mesonero|encargado|encapuchado|emisario|anciano|anciana|enano|enana)\b(?<relative>\s*,?\s+que\s+(?:(?:me|te|le|les|nos|os)\s+)?(?:dice|responde|pregunta|exclama|replica|gruñe|añade|continúa|grita|susurra|chilla|maldice|contesta)\b)/iu
  @own_speech ~r/\b(?:pregunto|digo|respondo|exclamo|añado|replico)\b/iu

  def npc_speech_verbs, do: @npc_speech_verbs
  @doc "Verb-first NPC attributions; group 1 captures the speaker."
  def npc_attributions, do: [@npc_attr]
  def npc_role_name, do: @npc_role_name
  def npc_named, do: @npc_named
  def npc_name_speaks, do: @npc_name_speaks
  def npc_voice_colon, do: @npc_voice_colon
  def npc_role_speaks, do: @npc_role_speaks
  def npc_role_relative_speaks, do: @npc_role_relative_speaks
  def own_speech, do: @own_speech

  # Exploration + human at the table: an AI PC must propose, not finish the
  # job (open the scroll, pick the item, walk off). Combat is untouched.
  @solo_exec ~r/\b(?:desliza la uña|quiebra (?:el|un) (?:lacre|sello|pergamino)|despliega el pergamino|rompe el lacre|recoge (?:la|el)|coge (?:la|el)|toma la pluma|lanza un|conjura |dispara un|camina hacia|se encamina|desaparece en|lee en voz alta|una hora andando)\b/iu
  def solo_exec, do: @solo_exec

  # --------------------------------------------------- addressing a PC

  @question_cues [
    ~r/\bante ti\b/iu,
    ~r/\bpara ti\b/iu,
    ~r/¿?\s*qué hace(?:s|is|n)?\b/iu,
    ~r/\btú\b/u,
    ~r/\bsi quieres\b/iu,
    ~r/\bte toca\b/iu,
    ~r/\bes tu (?:turno|decisi[oó]n)\b/iu
  ]

  @doc "Non-punctuation cues that a DM line is a prompt to a PC."
  def question_cues, do: @question_cues

  @doc "A name inside an open `¿…` question counts as its recipient."
  def name_in_open_question, do: ~r/¿[^?]{0,100}$/u

  @doc "Coordinating conjunctions between vocatives (`Vex y Lyra`)."
  def and_alt, do: "y|e"

  @vocative_question ~r/^(?:[—–]\s*)?(.+?),\s*¿([^?]+)\?/su
  def vocative_question, do: @vocative_question

  # The interrogative can carry its preposition: "¿De qué…?" is still spoken
  # information, not an action to paraphrase. Recipient and tail guards stay
  # authoritative; only one preposition + accented interrogative is added.
  @prepositional_information ~S"(?:a|ante|bajo|con|contra|de|desde|en|entre|hacia|hasta|para|por|según|sin|sobre|tras)\s+(?:qué|cuál(?:es)?|quién(?:es)?|dónde|cómo|cuándo|cuánto(?:s|as|a)?)"
  @pc_question_information ~r/^¿(?:(?:tú|vosotros|vosotras)\s+)?(?:qué|cuál(?:es)?|quién(?:es)?|dónde|cómo|cuándo|cuánto(?:s|as|a)?|#{@prepositional_information}|recuerdas|recordáis|sabes|sabéis|viste|visteis|oíste|oísteis|escuchaste|escuchasteis)\b/iu
  @pc_speech_wait ~r/^(?:(?:yo\s+)?espero(?:\s+(?:aquí|allí|junto\s+a\s+la\s+barra|ante\s+la\s+puerta))?(?:\s+(?:tu\s+respuesta|vuestras?\s+respuestas?|las\s+respuestas))?(?:\s+antes\s+de\s+decidir(?:\s+qué\s+hacer)?)?)?\.?$/iu

  def pc_question_information, do: @pc_question_information
  def pc_speech_wait, do: @pc_speech_wait

  @question_run ~r/^((?:¿[^¿?]+\?\s*){1,3})(.*)$/su
  @question_item ~r/¿[^¿?]+\?/u
  @question_body ~r/^(?:¿[^¿?]+\?\s*){1,3}$/u
  @vocative_joiner ~r/^(?:,\s*(?:(?:y|e)\s+)?|(?:y|e)\s+)(.+)$/iu

  @doc "Up to three leading questions (group 1) and the tail after them (group 2)."
  def question_run, do: @question_run
  @doc "One question inside a run."
  def question_item, do: @question_item
  @doc "A speech made only of one to three questions."
  def question_body, do: @question_body
  @doc "The separator before the next vocative name (group 1 is the rest)."
  def vocative_joiner, do: @vocative_joiner

  # ------------------------------------------------- questions to an NPC

  @npc_roles Enum.join(
               ~w(posadero posadera tabernero tabernera mesonero mesonera encargado encargada encapuchado encapuchada emisario emisaria anciano anciana enano enana zagal zagala cabrero cabrera pastor pastora molinero molinera herrero herrera mercader mercadera guardia guardabosques curandero curandera capitán capitana aprendiz),
               "|"
             )
  # A qualifier contains one noun, optionally preceded by an article. Longer
  # descriptions or clauses remain on the semantic route rather than swallowing
  # actions into a supposedly literal recipient.
  @npc_qualifier ~S"(?:\s+(?:de\s+(?:(?:el|la|los|las)\s+)?|del\s+)[\p{L}\p{M}][\p{L}\p{M}'’\-]{0,39})?"
  @npc_role "(?:#{@npc_roles})#{@npc_qualifier}"
  @npc_address ~r/^(?:desde\s+[^\n.!?¿:«»"“”]{1,80}\s+)?(?:le\s+)?pregunto\s+(?<recipient>(?:a\s+(?:el|la)|al)\s+#{@npc_role})\s*[:,]\s*$/iu
  @npc_question ~r/^(?:desde\s+[^\n.!?¿:«»"“”]{1,80}\s+)?(?:le\s+)?pregunto\s+(?<recipient>(?:a\s+(?:el|la)|al)\s+#{@npc_role})\s*[:,]\s*[«“"]?(?:antes de\s+[^\n,.!?¿]{1,40},\s*)?¿[^?]+\?/iu
  @npc_vocative_question ~r/^(?:[—–]\s*)?(?<recipient>(?:el|la)\s+#{@npc_role})\s*,\s*¿[^?]+\?/iu
  # Case folding applies to the sentence, but the name must start uppercase.
  # Multiword names/descriptions stay on the semantic route. Roster context is
  # required so a PC's first name cannot accidentally become an NPC recipient.
  @npc_proper_name "(?-i:[\\p{Lu}][\\p{L}\\p{M}'’\\-]{2,39})"
  @npc_named_address ~r/^(?:desde\s+[^\n.!?¿:«»"“”]{1,80}\s+)?(?:le\s+)?pregunto\s+(?<recipient>a\s+#{@npc_proper_name})\s*[:,]\s*$/iu
  @npc_named_question ~r/^(?:desde\s+[^\n.!?¿:«»"“”]{1,80}\s+)?(?:le\s+)?pregunto\s+(?<recipient>a\s+#{@npc_proper_name})\s*[:,]\s*[«“"]?(?:antes de\s+[^\n,.!?¿]{1,40},\s*)?¿[^?]+\?/iu
  @npc_named_vocative_question ~r/^(?:[—–]\s*)?(?<recipient>#{@npc_proper_name})\s*,\s*¿[^?]+\?/iu

  def npc_address, do: @npc_address
  def npc_question, do: @npc_question
  def npc_vocative_question, do: @npc_vocative_question
  def npc_named_address, do: @npc_named_address
  def npc_named_question, do: @npc_named_question
  def npc_named_vocative_question, do: @npc_named_vocative_question

  @doc "Normalized NPC recipient label (`al posadero` → `el posadero`)."
  def normalize_recipient(recipient) do
    recipient
    |> String.replace(~r/^al\s+/iu, "el ")
    |> String.replace(~r/^a\s+/iu, "")
    |> String.downcase()
  end

  @doc "Leading article dropped when comparing an NPC label with PC names."
  def leading_article, do: ~r/^(?:el|la)\s+/u

  @npc_speech_spatial ~r/^desde\s+(?:la\s+(?:ventana|barra|puerta|mesa)|el\s+(?:umbral|patio|camino)|aquí|allí)\s+/iu
  @npc_speech_information ~r/^¿(?:qué|cuál(?:es)?|quién(?:es)?|dónde|cómo|cuándo|cuánto(?:s|as|a)?|#{@prepositional_information}|tú\s+eres|eres|hay|sabes\s+si|(?:tú\s+)?(?:viste|oíste|escuchaste)|te\s+referías|llegaste\s+a\s+(?:ver|oír|escuchar))\b/iu
  @npc_speech_wait ~r/^(?:(?:yo\s+)?espero(?:\s+(?:aquí|allí|junto\s+a\s+la\s+barra|ante\s+la\s+puerta))?(?:\s+su\s+respuesta)?(?:\s+antes\s+de\s+pedir)?|me\s+quedo\s+(?:aquí|allí|ante\s+la\s+puerta|junto\s+a\s+la\s+barra)(?:\s+y\s+espero\s+su\s+respuesta)?)?\.?$/iu
  @npc_quoted_speech ~r/^(?<prefix>[^«»“”"]{1,160})(?<open>[«“"])(?<speech>[^«»“”"]{1,1800})(?<close>[»”"])(?<tail>.*)$/su
  @npc_recall_preface ~r/^cuando\s+(?:dijiste|decías|dices|afirmaste|afirmabas|afirmas|comentaste|comentabas|comentas|mencionaste|mencionabas|mencionas)\s+[^\n,.!?¿]{1,100},\s*$/iu

  def npc_speech_spatial, do: @npc_speech_spatial
  def npc_speech_information, do: @npc_speech_information
  def npc_speech_wait, do: @npc_speech_wait
  def npc_quoted_speech, do: [@npc_quoted_speech]
  def npc_recall_preface, do: @npc_recall_preface

  @doc "Closing quotes accepted for each opening quote."
  def quote_pairs, do: %{"«" => ["»"], "“" => ["”"], "\"" => ["\""]}

  @doc "Regex source of the literal prefix before an NPC question (`role` already escaped)."
  def npc_literal_prefix(role),
    do: "^(?:le\\s+)?pregunto\\s+#{role}\\s*[:,]\\s*[«“\"]?(?:antes\\s+de\\s+salir,\\s*)?$"

  @doc "Regex source of the companions-may-listen clause (`names` already escaped)."
  def listeners(names),
    do: "^(?:#{names})(?:\\s*(?:,|y|e)\\s*(?:#{names}))*\\s+pueden\\s+escuchar[.;]\\s*"

  @doc "Closing quote/period after a single unquoted NPC question."
  def question_tail_opener, do: ~r/^\s*[»”"]?\s*\.?\s*/u
end
