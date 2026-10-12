defmodule Dragonex.Text.Lexicon.En do
  @moduledoc """
  English vocabulary of `Dragonex.Text`: the same intent as
  `Dragonex.Text.Lexicon.Es`, written for English prose.

  Notable differences from the Castilian lexicon:

    * Questions carry no opening mark, so the parsers locate a question by
      its closing `?` and an interrogative/auxiliary opening word.
    * There are no clitics; one bounded adverb ("already", "quietly", any
      `-ly`) may sit between a PC's name and its verb instead.
    * "you" is both singular and plural. Only explicit plurals ("you all",
      "both of you") and singular decisions ("you decide to…") count as
      collective agency, so ordinary second-person narration of the human's
      own declared action ("You cross the bridge") is not cut.
    * Speech can be attributed name-first ("…," Lyra says) as well as
      verb-first ("…," says Lyra).
  """

  # ---------------------------------------------------------------- scrub

  @doc "English questions only close with `?`."
  def inverted_questions?, do: false

  @doc """
  English closes sentence punctuation inside the quotation (`"Wait." The
  door…`): a sentence ends there when the next one starts with a capital.
  """
  def closed_quote_boundary, do: ~r/(?<=[.!?…]["”])\s+(?=[\p{Lu}«“"])/u

  def fused_roll_words, do: "check|attack|roll|saving|save"

  @inline_hp_xy ~r/\b\d{1,4}\s*\/\s*\d{1,4}\s*(?:hp|pg|hit points?)\b/i
  @inline_bare_hp ~r/\b(?:\d{1,4}\s*(?:hp|hit points?)(?:\s+(?:left|remaining))?|hp\s*\d{1,4})\b/i
  @inline_points ~r/\b\d{1,4}\s*hit points?\b/i
  @inline_of_total ~r/\b\d{1,4}\s*(?:of|out of)\s*(?:(?:the|their|his|her|its)\s+)?\d{1,4}\s*(?:original\s+)?hit points?\b/i
  @inline_ac ~r/\b(?:AC|CA)\s*(?::|=|is|of)?\s*\d{1,4}\b/
  @inline_ac_long ~r/\barmou?r class\s*(?::|=|is|of)?\s*\d{1,4}\b/i
  @stats_parens ~r/\([^)]*(?:\b(?:AC|HP)\b\s*(?:[:=]|\s*is\s*|\s*of\s*)?\s*\d|\d{1,4}\s*\/\s*\d{1,4})[^)]*\)/i
  @hp_left ~r/\b(?:hp|hit points)\s+(?:left|remaining)\b/i

  def inline_hp_xy, do: @inline_hp_xy
  def inline_bare_hp, do: @inline_bare_hp
  def inline_points, do: @inline_points
  def inline_of_total, do: @inline_of_total
  def inline_ac, do: @inline_ac
  def inline_ac_long, do: @inline_ac_long
  def stats_parens, do: @stats_parens
  def hp_left, do: @hp_left

  @orphan_of ~r/\b\d{1,4}\s+(?:of|out of)\s*(?:\*\*)?\s*(?=\*\*|[.,;:!?…]|$)/u
  @dangling_stat ~r/\b(is left with|is down to|drops to|falls to|is at|has|with)\s*(?=[.,;!?…]|$)/iu

  def orphan_of, do: @orphan_of
  def dangling_stat, do: @dangling_stat

  @tool_leak_words ~r/\b(?:attack|attacks|check|roll|damage|saving|save|initiative)\b/i
  def tool_leak_words, do: @tool_leak_words

  @recap_headers ~r/^\s*\*{0,2}\s*(?:(?:Combat|Battle)\s+(?:Status|State|Summary)|Current\s+(?:Status|Situation)|Status|Situation|Summary|Combat|Stats?|Battle)\s*\*{0,2}\s*[:：]\s*\*{0,2}\s*$/i
  @recap_row_hp ~r/\d{1,4}\s*\/\s*\d{1,4}\s*(?:hp|pg)/i
  @recap_row_ac ~r/\b(?:AC|CA)\s*\d+/i

  def recap_headers, do: @recap_headers
  def recap_row_hp, do: @recap_row_hp
  def recap_row_ac, do: @recap_row_ac

  @engine_meta [
    ~r/\bthe (?:system|engine|framework|backend)\s+(?:resolves|decides|processes|returns|handles)[^.]*\./i,
    ~r/\bthe (?:tool|function)\s+(?:resolves|returns|processes)[^.]*\./i,
    ~r/\bthe scene (?:resets|is reset)[^.]*\./i,
    ~r/\bI(?:'ll|’ll| will)? materiali[sz]e (?:it|this)(?:\s+in the world)?[^.]*\./i,
    ~r/\b(?:so (?:that )?it(?:'s|’s| is) (?:official|recorded|on record)|for the record|to make it official)[^.]*\./i,
    ~r/(?:\bI,?\s+)?\bas (?:the )?DM\b[^.]*\./i,
    ~r/\bthe success of the (?:check|study|examination|roll)[^.]*\./i,
    # The engine's own turn cue ("It's YOUR turn (DM)") echoed back as prose.
    ~r/[^.!?]*\bturno?\s*\(\s*DM\s*\)[^.!?]*[.!?]*\s*/iu
  ]

  def engine_meta, do: @engine_meta

  @narrated_tool_brackets ~r/\[(?:establish(?:ing)? )?(?:fact|spawn|invocation|narration|action)\s*[:=][^\]]*\]/i
  def narrated_tool_brackets, do: @narrated_tool_brackets

  # ------------------------------------------------------------- puppeting

  # Proactive predicates of a PC (third person, plus bare forms used after
  # "you all"/"we" elsewhere). Entries are regex sources; passive states
  # ("is wounded", "falls", "stays", "remains", "stands") are deliberately
  # absent. "takes" excludes the engine's "takes 5 damage"/"takes a hit".
  @puppet_verbs [
    "attacks",
    "strikes",
    "hits",
    "swings",
    "casts",
    "conjures",
    "shoots",
    "fires",
    "draws",
    "unsheathes",
    "aims",
    "nocks",
    "readies",
    "prepares",
    "charges",
    "leaps",
    "jumps",
    "runs",
    "chases",
    "pursues",
    "lunges",
    "rushes",
    "summons",
    "invokes",
    "advances",
    "crosses",
    "climbs",
    "descends",
    "enters",
    "leaves",
    "exits",
    "steps",
    "moves",
    "opens",
    "closes",
    "pushes",
    "pulls",
    "grabs",
    "seizes",
    "takes(?!\\s+(?:\\d|damage|a\\s+(?:hit|blow|wound)|the\\s+(?:hit|blow)))",
    "picks",
    "drops",
    "turns",
    "examines",
    "inspects",
    "searches",
    "studies",
    "says",
    "speaks",
    "talks",
    "nods",
    "shouts",
    "yells",
    "whispers",
    "asks",
    "replies",
    "answers",
    "responds",
    "exclaims",
    "retorts",
    "decides",
    "agrees",
    "accepts",
    "approaches",
    "walks",
    "heads",
    "kneels",
    "crouches",
    "stands\\s+up",
    "gets\\s+up"
  ]

  # Gestures matched as the PC's immediate predicate, as in Spanish.
  @puppet_direct "(?:raises|lifts|tunes|comments|remarks|leafs|flips|gathers|(?:keeps|continues)\\s+(?:leafing|flipping|reading))"

  @puppet_adverb "(?:(?:already|then|also|just|now|simply|finally|suddenly|immediately|\\p{L}{3,}ly)\\s+)?"

  @puppet_qualified_action "#{@puppet_adverb}(?:(?:#{Enum.join(@puppet_verbs, "|")})|#{@puppet_direct})"

  def puppet_qualified_action, do: @puppet_qualified_action
  def relative_pronoun, do: "(?:who|which)"
  def subordinators, do: "(?:when|while|as)"

  @pc_environment_tail ~r/,\s+and\s+(?=(?:the|a|an)\s+(?:air|light|heat|warmth|cold|breeze|wind|rain|fire|bird|jay|oak|door|window|room|hall|table)\b)/iu
  def pc_environment_tail, do: @pc_environment_tail

  @plural_moves "(?:cross|advance|set\\s+(?:off|out)|depart|leave|enter|decide|agree|accept|walk|head|approach|venture|move\\s+on|follow)"

  @collective_patterns [
    ~r/^\s*(?:—\s*)?(?:the group|the party|the team|the company)\s+(?:already\s+)?(?:crosses|advances|sets\s+(?:off|out)|departs|leaves|enters|decides|agrees|accepts|walks|heads|approaches|ventures|moves\s+on)\b/iu,
    ~r/^\s*(?:—\s*)?(?:the adventurers|the heroes|the companions)\s+(?:already\s+)?#{@plural_moves}\b/iu,
    ~r/^\s*(?:—\s*)?(?:you\s+(?:all|both|two)|all\s+of\s+you|both\s+of\s+you|the\s+(?:two|three|four|five|six)\s+of\s+you)\s+(?:already\s+)?(?:#{@plural_moves}|attack|charge|draw|nod)\b/iu,
    ~r/^\s*(?:—\s*)?you\s+(?:already\s+)?(?:decide\s+to|agree\s+(?:to|on)|choose\s+to|accept\s+the)\b/iu,
    ~r/^\s*(?:—\s*)?we(?:\s+all)?\s+(?:already\s+)?#{@plural_moves}\b/iu,
    ~r/^\s*(?:—\s*)?the\s+decision\s+(?:is|was|has(?:\s+already)?\s+been)\s+(?:already\s+)?(?:made|taken)\s+(?:between|among)\s+(?:you|all\s+of\s+you)\b/iu
  ]

  def collective_patterns, do: @collective_patterns

  def collective_heads,
    do: [
      "the group",
      "the party",
      "the team",
      "the company",
      "the decision",
      "the adventurers",
      "the heroes",
      "the companions",
      "you",
      "all of you",
      "both of you",
      "we",
      "as",
      "when",
      "once"
    ]

  @implicit_party_movement ~r/\b(?:as|when|once)\s+(?:you|we)(?:\s+(?:all|both))?\s+(?:approach|near|draw\s+(?:near|closer)|get\s+closer|head|venture|move\s+away|step\s+(?:away|aside)|walk\s+away|pull\s+away|leave)\b(?:(?:\s+(?:to|toward|towards|into|in|inside|out\s+of|away\s+from|from|through|up\s+to|closer\s+to|near|the|a|an)\b[^,;.!?…:«»“"\n]{0,120})?(?:,|(?=[;.!?…:«»“"\n]|$)))?\s*/iu
  @implicit_party_gesture ~r/(?:,\s*)?(?:\band\s+)?\b(?:(?:you|we)\s+(?:all\s+|both\s+)?(?:exchange|trade)\s+(?:a\s+)?(?:glances?|looks?)|(?:you|we)\s+(?:all\s+|both\s+)?look\s+at\s+each\s+other)\b(?:\s+(?:for\s+a\s+moment|for\s+a\s+few\s+seconds|in\s+silence|among\s+yourselves))?/iu
  @implicit_party_plan ~r/\b(?:if|could|can|may|might|propose|suggest|perhaps|maybe|let's|let’s|let\s+us)\b/iu
  @implicit_lead ~r/^\s*(?:as|when|once)\s+/iu
  @trailing_conj ~r/\s+(?:and|but|while|when|then)\s*$/iu

  def implicit_party_movement, do: @implicit_party_movement
  def implicit_party_gesture, do: @implicit_party_gesture
  def implicit_party_plan, do: @implicit_party_plan
  def implicit_lead, do: @implicit_lead
  def trailing_conj, do: @trailing_conj

  @speech_verbs "(?:says|asks|replies|answers|adds|retorts|exclaims|whispers|shouts|murmurs|mutters|comments|remarks)"
  @speech_attribution ~r/^\s*[,—-]?\s*#{@speech_verbs}\s+/iu
  # A pronoun ("…," she says) names nobody: it behaves like an implicit
  # attribution and keeps the previous speaker.
  @speech_attribution_name_first ~r/^(?>\s*[,—-]?\s*)(?!(?:he|she|they|it|I|we|you)\b)(\p{L}.{0,59}?)\s+#{@speech_verbs}\b/iu

  def speech_attribution, do: @speech_attribution
  @doc "Name-first attribution after a quote (`\"…,\" Lyra says`); group 1 is the speaker."
  def speech_attribution_name_first, do: @speech_attribution_name_first

  # ------------------------------------------------------ PC world leaks

  @time_skips [
    ~r/\b(?:half an hour|an hour|a while|a few minutes|a few hours|several days|a couple of hours|some time)\s+later\b/iu,
    ~r/\b(?:hours?|days?|minutes?)\s+later\b/iu,
    ~r/\bafter\s+(?:a while|an hour|a few hours|a few minutes|several hours)\b/iu,
    ~r/\b(?:the\s+)?(?:next|following)\s+(?:day|morning|dawn|evening|night)\b/iu
  ]

  def time_skips, do: @time_skips

  @npc_verbs "(?:says|replies|asks|exclaims|retorts|growls|adds|continues|shouts|shouting|whispers|answers|mutters)"
  @roles "(?:innkeeper|barkeep|barkeeper|bartender|tavernkeeper|steward|hooded\\s+figure|emissary|elder|old\\s+(?:man|woman)|dwarf)"

  @npc_speech_verbs ~r/\b(?:says|replies|asks|exclaims|retorts|growls|adds|continues|shouts|shouting|whispers|shrieks|curses|answers|mutters|murmurs)\b/iu
  # Verb-first ("says the innkeeper") and subject-first ("the innkeeper
  # says"); group 1 is the speaker in both.
  @npc_attributions [
    ~r/\b#{@npc_verbs}\s+the\s+(\w+)/iu,
    ~r/\bthe\s+(\w+)\s+#{@npc_verbs}\b/iu
  ]
  @npc_role_name ~r/^(?:innkeeper|barkeep|barkeeper|bartender|tavernkeeper|steward|hooded|emissary|elder|old|dwarf|guard|merchant|stranger|witness)\b/iu
  @npc_named ~r/\b#{@npc_verbs}\s+(\p{Lu}[\p{L}\p{M}]+)/u
  @npc_name_speaks ~r/\b(\p{Lu}[\p{L}\p{M}]+)\s+(?:says|replies|asks|exclaims|retorts|growls|adds|continues|lowers\s+(?:his|her|their)\s+voice|shouts|shouting|whispers|curses|answers)\s*:/u
  @npc_voice_colon ~r/\b(?:lowers\s+(?:his|her|their)\s+voice|says\s+in\s+a\s+\w+\s+voice|answers|replies\s+in\s+a\s+\w+\s+voice|shouts|shouting|shrieks|howls|curses|whispers|bellows)\s*:/iu
  @npc_role_speaks ~r/(?:^|[,;:]\s*|\b(?:and|but|while|when)\s+)the\s+#{@roles}\b.{0,120}[—«"“]/iu
  @npc_role_relative_speaks ~r/\b(?:the|to\s+the|of\s+the)\s+#{@roles}\b(?<relative>\s*,?\s+who\s+(?:says|replies|asks|exclaims|retorts|growls|adds|continues|shouts|whispers|shrieks|curses|answers|tells)\b)/iu
  @own_speech ~r/\bI\s+(?:ask|say|reply|answer|exclaim|add|retort|tell|whisper|call\s+out)\b/iu

  def npc_speech_verbs, do: @npc_speech_verbs
  def npc_attributions, do: @npc_attributions
  def npc_role_name, do: @npc_role_name
  def npc_named, do: @npc_named
  def npc_name_speaks, do: @npc_name_speaks
  def npc_voice_colon, do: @npc_voice_colon
  def npc_role_speaks, do: @npc_role_speaks
  def npc_role_relative_speaks, do: @npc_role_relative_speaks
  def own_speech, do: @own_speech

  @solo_exec ~r/\b(?:(?:she|he|they|I)\s+)?(?:slides?\s+(?:a|her|his|my|their)\s+(?:finger)?nail|breaks?\s+(?:the|a)\s+(?:wax|seal|scroll|parchment)|unrolls?\s+the\s+(?:scroll|parchment)|picks?\s+up\s+the|grabs?\s+the|takes?\s+the\s+quill|casts?\s+an?\s+(?!glow|shadow|light)|fires?\s+an?\b|shoots?\s+an?\b|walks?\s+(?:toward|towards)|heads?\s+(?:off|out|toward|towards)|disappears?\s+into|reads?\s+(?:it\s+)?aloud|an\s+hour(?:'s|’s)\s+walk)/iu
  def solo_exec, do: @solo_exec

  # --------------------------------------------------- addressing a PC

  @question_cues [
    ~r/\bbefore you\b/iu,
    ~r/\bfor you\b/iu,
    ~r/\bwhat (?:do|will|would) you do\b/iu,
    ~r/\bif you (?:want|wish|like)\b/iu,
    ~r/\byour (?:turn|decision|call)\b/iu,
    ~r/\bup to you\b/iu
  ]

  def question_cues, do: @question_cues

  @doc "Without `¿` there is no open question to look back into."
  def name_in_open_question, do: ~r/\A(?!)/u

  def and_alt, do: "and"

  @doc "Unused in English (no opening mark); the vocative is parsed by name."
  def vocative_question, do: nil

  @interrogative "(?:what|which|who|whom|whose|where|when|why|how|is|are|was|were|do|does|did|have|has|had|can|could|will|would|should|may|might|shall)\\b"
  @prepositional_information "(?:in|on|at|from|with|about|to|for|by|of|into|toward|towards|under|over|after|before)\\s+(?:what|which|who|whom|whose|where|when|how\\s+(?:many|much))"

  @pc_question_information ~r/^(?:(?:and|so)\s+)?(?:what|which|who|whom|whose|where|how|when|why|#{@prepositional_information}|do\s+you\s+(?:remember|recall|know)|did\s+you\s+(?:see|hear|notice)|have\s+you\s+(?:seen|heard))\b/iu
  @pc_speech_wait ~r/^(?:(?:I\s+)?wait(?:\s+(?:here|there|by\s+the\s+bar|at\s+the\s+door))?(?:\s+for\s+(?:your\s+(?:answers?|replies|reply)|the\s+answers?|their\s+answers?))?(?:\s+before\s+deciding(?:\s+what\s+to\s+do)?)?)?\.?$/iu

  def pc_question_information, do: @pc_question_information
  def pc_speech_wait, do: @pc_speech_wait

  @question_run ~r/^((?:[^?.!¿\n]+\?\s*){1,3})(.*)$/su
  @question_item ~r/[^?.!\s][^?.!]*\?/u
  @question_body ~r/^(?:[^?.!]+\?\s*){1,3}$/u
  @vocative_joiner ~r/^(?:,\s*(?:and\s+)?|and\s+)(.+)$/iu

  def question_run, do: @question_run
  def question_item, do: @question_item
  def question_body, do: @question_body
  def vocative_joiner, do: @vocative_joiner

  # ------------------------------------------------- questions to an NPC

  @npc_roles Enum.join(
               ~w(innkeeper barkeeper barkeep bartender tavernkeeper steward emissary elder dwarf boy girl lad lass goatherd shepherdess shepherd miller blacksmith smith merchant trader guard ranger forester healer captain apprentice farmer fisherman priestess priest),
               "|"
             ) <> "|old\\s+(?:man|woman)|hooded\\s+(?:figure|man|woman)"
  @npc_qualifier ~S"(?:\s+(?:of|from|with)\s+(?:(?:the|a|an)\s+)?[\p{L}\p{M}][\p{L}\p{M}'’\-]{0,39})?"
  @npc_role "(?:#{@npc_roles})#{@npc_qualifier}"
  @spatial "(?:from\\s+[^\\n.!?:«»\"“”]{1,80}?,?\\s+)?"
  @open_quote "[«“\"'‘]?"
  @npc_address ~r/^#{@spatial}I\s+ask\s+(?<recipient>the\s+#{@npc_role})\s*[:,]\s*$/iu
  @npc_question ~r/^#{@spatial}I\s+ask\s+(?<recipient>the\s+#{@npc_role})\s*[:,]\s*#{@open_quote}(?:before\s+[^\n,.!?]{1,40},\s*)?(?<question>#{@interrogative}[^?]*\?)/iu
  @npc_vocative_question ~r/^(?:[—–]\s*)?(?<recipient>(?:the\s+)?#{@npc_role})\s*,\s*(?<question>#{@interrogative}[^?]*\?)/iu
  @npc_proper_name "(?-i:(?!The\\b|I\\b)[\\p{Lu}][\\p{L}\\p{M}'’\\-]{2,39})"
  @npc_named_address ~r/^#{@spatial}I\s+ask\s+(?<recipient>#{@npc_proper_name})\s*[:,]\s*$/iu
  @npc_named_question ~r/^#{@spatial}I\s+ask\s+(?<recipient>#{@npc_proper_name})\s*[:,]\s*#{@open_quote}(?:before\s+[^\n,.!?]{1,40},\s*)?(?<question>#{@interrogative}[^?]*\?)/iu
  @npc_named_vocative_question ~r/^(?:[—–]\s*)?(?<recipient>#{@npc_proper_name})\s*,\s*(?<question>#{@interrogative}[^?]*\?)/iu

  def npc_address, do: @npc_address
  def npc_question, do: @npc_question
  def npc_vocative_question, do: @npc_vocative_question
  def npc_named_address, do: @npc_named_address
  def npc_named_question, do: @npc_named_question
  def npc_named_vocative_question, do: @npc_named_vocative_question

  @bare_role Regex.compile!("^(?:#{@npc_role})$", "iu")

  @doc "Normalized NPC recipient label: lowercase, roles with their article (`the innkeeper`)."
  def normalize_recipient(recipient) do
    recipient = recipient |> String.trim() |> String.downcase()
    if Regex.match?(@bare_role, recipient), do: "the " <> recipient, else: recipient
  end

  def leading_article, do: ~r/^the\s+/u

  @npc_speech_spatial ~r/^from\s+(?:the\s+(?:window|bar|door|doorway|table|threshold|courtyard|road|path)|here|there),?\s+/iu
  @npc_speech_information ~r/^(?:(?:and|so)\s+)?(?:what|which|who|whom|whose|where|how|when|why|#{@prepositional_information}|are\s+you|is\s+there|are\s+there|is\s+it|do\s+you\s+know\s+(?:if|whether)|did\s+you\s+(?:see|hear|notice)|have\s+you\s+(?:seen|heard)|were\s+you\s+referring|did\s+you\s+mean|did\s+you\s+get\s+to\s+(?:see|hear))\b/iu
  @npc_speech_wait ~r/^(?:(?:I\s+)?wait(?:\s+(?:here|there|by\s+the\s+bar|at\s+the\s+door))?(?:\s+for\s+(?:(?:his|her|their)\s+(?:answer|reply)|an\s+answer))?(?:\s+before\s+(?:asking|ordering))?|I\s+stay\s+(?:here|there|at\s+the\s+door|by\s+the\s+bar)(?:\s+and\s+wait\s+for\s+(?:his|her|their)\s+(?:answer|reply))?)?\.?$/iu
  @npc_quoted_double ~r/^(?<prefix>[^«»“”"]{1,160})(?<open>[«“"])(?<speech>[^«»“”"]{1,1800})(?<close>[»”"])(?<tail>.*)$/su
  # Single quotes double as apostrophes ("What's"): the closing quote must be
  # followed by whitespace or the end of the text.
  @npc_quoted_single ~r/^(?<prefix>[^«»“”"'‘’]{1,160})(?<open>['‘])(?<speech>[^«»“”"‘]{1,1800}?)(?<close>['’])(?<tail>(?=\s|$).*)$/su
  @npc_recall_preface ~r/^when\s+you\s+(?:said|were\s+saying|say|mentioned|told\s+(?:me|us)|claimed|commented)\s+[^\n,.!?]{1,100},\s*/iu

  def npc_speech_spatial, do: @npc_speech_spatial
  def npc_speech_information, do: @npc_speech_information
  def npc_speech_wait, do: @npc_speech_wait
  def npc_quoted_speech, do: [@npc_quoted_double, @npc_quoted_single]
  @doc "Recall preface opening the first question (`When you said X, …`)."
  def npc_recall_preface, do: @npc_recall_preface

  def quote_pairs,
    do: %{"«" => ["»"], "“" => ["”"], "\"" => ["\""], "'" => ["'", "’"], "‘" => ["’", "'"]}

  def npc_literal_prefix(role),
    do:
      "^I\\s+ask\\s+#{role}\\s*[:,]\\s*[«“\"'‘]?(?:before\\s+(?:I\\s+)?(?:leave|leaving|go|going),\\s*)?$"

  def listeners(names),
    do:
      "^(?:#{names})(?:\\s*(?:,|and)\\s*(?:#{names}))*\\s+(?:can|may)\\s+(?:listen|hear)(?:\\s+in)?[.;]\\s*"

  def question_tail_opener, do: ~r/^\s*[»”"'’]?\s*\.?\s*/u
end
