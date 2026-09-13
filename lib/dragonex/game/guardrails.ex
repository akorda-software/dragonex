defmodule Dragonex.Game.Guardrails do
  @moduledoc """
  Prompt-quality guardrails for the DM and AI PC agents.

  These are pure heuristics over the event timeline + the world: they detect
  stalls, puppeting, repetition, language drift and unspawned hostiles, and
  stitch a corrective nudge onto a beat's instruction text. They never touch the
  GenServer state — they take a `game_id` (and sometimes the `World`) and return
  either a boolean or a (possibly unchanged) instruction string.

  Extracted from `Dragonex.Game` so the turn-loop process stays focused on
  orchestration; this is the single biggest cohesive block that had zero coupling
  with the GenServer mechanics.
  """

  require Logger

  alias Dragonex.{Games, World}

  # ===========================================================================
  # Public API — called from `Dragonex.Game.advance/1` while building a beat's
  # instruction. Each `with_*` decorator returns the (possibly amended) base
  # instruction; each `*_limbo?` predicate returns a boolean.
  # ===========================================================================

  @doc "True when combate recently ended but the timeline hasn't moved past it."
  @spec post_combat_limbo?(term()) :: boolean()
  def post_combat_limbo?(events) when is_list(events), do: post_combat_limbo_from(events)

  def post_combat_limbo?(game_id) do
    events = Games.recent_events(game_id, 12)
    post_combat_limbo_from(events)
  end

  defp post_combat_limbo_from(events) do
    events = Enum.take(events, -12)

    # Find the index of the most recent "El combate termina" system event.
    end_idx =
      events
      |> Enum.with_index()
      |> Enum.find_value(fn {e, idx} ->
        if e.type == :system and combat_end_note?(e.payload), do: idx
      end)

    if end_idx do
      # Count narrations + actions AFTER the combate-end marker. If 0 or just
      # the immediate aftermath, we're in limbo. Allow up to 3 narrations
      # (the post-combate reactions of each PC) before declaring the limbo
      # over — by then the DM should have moved on.
      events_after = Enum.drop(events, end_idx + 1)

      narrations_after =
        Enum.count(events_after, fn e -> e.type in [:narration, :action] end)

      # Also check that no scene-setting tool ran after the combate ended.
      scene_moved? =
        Enum.any?(events_after, fn e ->
          e.type == :system and (e.payload["note"] || "") =~ ~r/escena cambiada|set_scene/i
        end)

      narrations_after <= 4 and not scene_moved?
    else
      false
    end
  end

  defp combat_end_note?(%{"note" => note}) when is_binary(note),
    do: note =~ "El combate termina" or note =~ "combate termina"

  defp combat_end_note?(_), do: false

  # ---------------------------------------------------------------------------
  # Bug #4 — the DM sometimes narrates a PC acting on its behalf ("*Lyra
  # desenvaina y ataca*"). Rule 14 forbids this but the model still leaks.
  # Persist path now DROPS those clauses (`Text.strip_puppet_clauses`, D29).
  # The detector still drives a next-beat reminder for leaks the strip misses
  # (e.g. mid-clause puppets). Passive state ("Lyra cae herida") is not a hit.
  @doc """
  True when `text` describes a PC performing a proactive action (rule 14 leak).
  Pure helper so unit tests can pin the detector without a live Game.
  """
  @spec dm_narration_puppets_pc?(String.t(), [String.t()]) :: boolean()
  def dm_narration_puppets_pc?(text, pc_names),
    do: Dragonex.Text.dm_puppets_pc?(text, pc_names)

  @spec with_dm_no_puppet_nudge(term(), World.t(), String.t()) :: String.t()
  def with_dm_no_puppet_nudge(source, world, base_instruction) do
    events = events_of(source, 20)

    if dm_puppeted_a_pc?(events, world) do
      Logger.info("dragonex DM narrated a PC acting — reinforcing rule 14")
      dm_no_puppet_nudge() <> "\n\n" <> base_instruction
    else
      base_instruction
    end
  end

  defp dm_puppeted_a_pc?(events, %World{} = world) do
    # Include downed PCs: the DM must not puppet a fallen ally either.
    pc_names = pc_names(world)

    if pc_names == [] do
      false
    else
      case last_dm_narration(events) do
        nil -> false
        text -> dm_narration_puppets_pc?(text, pc_names)
      end
    end
  end

  # The DM's narration texts, most recent first. We sort by `seq` descending
  # explicitly (rather than relying on `recent_events`'s query order) so the
  # ordering is unambiguous regardless of how the query returns rows. Shared by
  # the anti-puppet check (needs the latest) and the anti-repeat check (needs
  # the last two).
  defp events_of(events, _n) when is_list(events), do: events
  defp events_of(game_id, n), do: Games.recent_events(game_id, n)

  defp dm_narration_texts(source) do
    source
    |> events_of(20)
    |> Enum.filter(fn e -> e.type == :narration and e.actor == "dm" end)
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.map(fn e -> e.payload["text"] || "" end)
    |> Enum.reject(&(&1 == ""))
  end

  defp last_dm_narration(source), do: List.first(dm_narration_texts(source))

  defp pc_names(%World{characters: chars}) do
    chars
    |> Enum.filter(fn {_, c} -> c.side == "pc" end)
    |> Enum.map(&elem(&1, 0))
  end

  defp dm_no_puppet_nudge do
    "⚠️ REGLA 14 — RECORDATORIO URGENTE ⚠️ En tu ÚLTIMA narración describiste a un " <>
      "personaje jugador (PC) HACIENDO algo: atacar, moverse, conjurar, tensar el arco, " <>
      "hablar, desenvainar… ESTÁ PROHIBIDO. Ejemplos PROHIBIDOS: «Lyra conjura firebolt», " <>
      "«Vex tensa su arco», «Vex aprovecha y dispara», «Rhogar se lanza al ataque». " <>
      "Ellos actúan SOLO en SU turno. Tú describes el mundo, monstruos, PNJ y consecuencias " <>
      "de lo que YA ocurrió. Si un PC aún no ha actuado, ESPERA — no rellenes su comportamiento."
  end

  # DM anti-repeat: when the DM reuses nearly the same line ("se desvanece en
  # una nube de humo sulfúrico" x N) it reads as a broken record. We compare the
  # last two DM narrations and, on a near-duplicate (Jaccard >= 0.7), force a
  # freshly-worded description this turn. Mirrors the PC anti-loop, but pitched
  # for narration variety rather than forcing a different action.
  @dm_repeat_threshold 0.7

  @spec with_dm_anti_repeat(term(), String.t()) :: String.t()
  def with_dm_anti_repeat(source, base_instruction) do
    case dm_narration_texts(source) do
      [a, b | _] when is_binary(a) and is_binary(b) ->
        if text_similarity(a, b) >= @dm_repeat_threshold do
          Logger.info("dragonex DM repeating narration — enforcing variety")
          dm_anti_repeat_nudge(a, base_instruction)
        else
          base_instruction
        end

      _ ->
        base_instruction
    end
  end

  defp dm_anti_repeat_nudge(last_text, base) do
    snippet = String.slice(String.trim(last_text), 0, 120)

    "⚠️ EVITA REPETIRTE ⚠️ Tu narración anterior fue prácticamente: «#{snippet}». " <>
      "NO reutilices esas mismas palabras ni esa misma imagen. Esta vez describe la " <>
      "escena, la criatura o la acción con un lenguaje y un enfoque NUEVOS y vívidos: " <>
      "cambia el detalle sensorial (olor, sonido, luz), el ángulo de la cámara, o el " <>
      "rasgo que destacas. Varía el ritmo y el vocabulario. Sé breve, pero fresco.\n\n" <>
      base
  end

  # Ghost combat v2: the DM narrates "aparece un esqueleto" / "se materializa un
  # demonio" but never calls spawn_monster, so no enemy exists in the World and
  # maybe_force_combat can't fire. The partida loops with the DM re-narrating
  # the appearance every turn. When the DM's last narration describes a hostile
  # appearing while we're in exploration with NO living enemies at all, we nudge
  # it to actually spawn the creature (the engine then forces initiative).
  @hostile_appear_verbs ~w(aparece aparecen materializa materializan irrumpe irrumpen surge surgen emerge emergen brota salen asoma asoman conjura invoca)
  @hostile_creatures ~w(goblin kobold bandit skeleton esqueleto wolf lobo orc orco hobgoblin ogre imp demonio diablillo diablo espinodemonio espinodemon trasgo draco dragon no-muerto muerto-viviente zombi zombie criatura monstruo bestia engendro siervo esbirro aberracion aberración elemental gargola gárgola licantropo licántropo vampiro espectro fantasma wraith)

  @spec with_dm_unspawned_hostile_nudge(term(), World.t(), String.t()) :: String.t()
  def with_dm_unspawned_hostile_nudge(source, %World{phase: :exploration} = world, base) do
    # No living enemies at all → a narrated appearance is a ghost the DM forgot
    # to spawn.
    if not World.has_living_enemies?(world) do
      case last_dm_narration(source) do
        nil ->
          base

        text ->
          if narrates_hostile_appearing?(text) do
            Logger.info(
              "dragonex DM narrated a hostile appearing without spawn_monster — nudging"
            )

            dm_spawn_nudge(base)
          else
            base
          end
      end
    else
      base
    end
  end

  def with_dm_unspawned_hostile_nudge(_source, _world, base), do: base

  defp narrates_hostile_appearing?(text) do
    verbs = @hostile_appear_verbs |> Enum.join("|")
    creatures = @hostile_creatures |> Enum.join("|")
    pattern = "(?:#{verbs})\\b[^.!?]{0,40}\\b(?:#{creatures})\\b"

    case Regex.compile(pattern, "i") do
      {:ok, re} -> Regex.match?(re, text)
      {:error, _} -> false
    end
  end

  defp dm_spawn_nudge(base) do
    "⚠️ HOSTIL SIN SPAWN ⚠️ En tu última narración describiste que un hostil aparece, " <>
      "pero NO existe en el mundo (no llamaste spawn_monster). ESTE TURNO DEBES materializarlo " <>
      "con spawn_monster(\"<kind>\", \"<nombre>\") — kinds disponibles: goblin, kobold, bandit, " <>
      "skeleton, wolf, orc, hobgoblin, ogre, training_dummy, archery_target — y el motor " <>
      "tirará iniciativa automáticamente. Si NO quieres combate real, NO narres que un hostil " <>
      "aparece: describe solo el entorno o un PNJ no hostil.\n\n" <> base
  end

  # Language guard. DeepSeek-v4-flash occasionally drifts into English for a
  # whole paragraph even though the system prompt says "responde en castellano".
  # We flag it by counting clearly-English stopwords (the/and/was/were/…) that
  # don't occur in normal Spanish prose; on a hit we reinforce the language rule
  # for the next beat. Conservative list: every marker here is unambiguously
  # English (no false friends with common Spanish words).
  @english_markers MapSet.new(~w(
    the and was were has have had will would should could might must shall
    this that these those they them their theirs its our ours your yours
    been being into onto upon about against through during before after without
    himself herself itself ourselves yourselves themselves there here from with
  ))

  @spec with_dm_spanish_nudge(term(), String.t()) :: String.t()
  def with_dm_spanish_nudge(source, base) do
    case last_dm_narration(source) do
      nil ->
        base

      text ->
        if looks_english?(text) do
          Logger.info("dragonex DM drifted into English — enforcing Spanish")
          dm_spanish_nudge(base)
        else
          base
        end
    end
  end

  defp dm_spanish_nudge(base) do
    "⚠️ IDIOMA ⚠️ Tu última narración contenía frases en INGLÉS. " <>
      "DEBES narrar, describir y dialogar EXCLUSIVAMENTE en CASTELLANO. " <>
      "Reescribe cualquier término, descripción o línea de diálogo en español. " <>
      "El inglés SOLO está permitido para nombres propios de lugares o personas que la biblia " <>
      "defina explícitamente en ese idioma; todo lo demás, en castellano.\n\n" <> base
  end

  # True when a text carries enough clearly-English function words to read as
  # English (threshold 5 — a Spanish paragraph almost never hits even 2).
  defp looks_english?(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\s]/u, " ")
      |> String.split(~r/\s+/, trim: true)

    Enum.count(words, &MapSet.member?(@english_markers, &1)) >= 5
  end

  # Exploration stall: a long run of pure narration with NO mechanical progress
  # (no ability check → :dice, no player declaration → :action, no spawn/scene →
  # :system note, no combat start). This is the "¿empezamos con el círculo?" x 10
  # turns pattern where everyone keeps re-declaring intentions without anyone
  # acting. When it hits, the DM is forced to advance the scene itself. Only
  # fires in exploration (combat has its own end-combat path) and only once a
  # meaningful backlog of narration has piled up, so a couple of scene-setting
  # lines right after setup don't trip it.
  @spec exploration_limbo?(term(), World.t()) :: boolean()
  def exploration_limbo?(events, %World{phase: :exploration}) when is_list(events) do
    recent =
      events
      |> Enum.take(-20)
      |> Enum.reject(fn e -> e.type in [:turn] end)
      |> Enum.take(8)

    # Need enough history to call it a stall (not a fresh partida), and every
    # recent meaningful event must be bare narration — any :dice, :action or
    # scene/spawn :system in the window means someone made progress.
    length(recent) >= 6 and Enum.all?(recent, &narration_only?/1)
  end

  def exploration_limbo?(game_id, %World{phase: :exploration} = world) do
    exploration_limbo?(Games.recent_events(game_id, 20), world)
  end

  def exploration_limbo?(_, _), do: false

  defp narration_only?(%{type: :narration}), do: true

  defp narration_only?(%{type: :system, payload: %{"note" => note}})
       when is_binary(note),
       do: not (note =~ ~r/escena cambiada|set_scene|spawn|toma la iniciativa|combate/i)

  defp narration_only?(%{type: :system}), do: true
  defp narration_only?(_), do: false

  # ---------------------------------------------------------------------------
  # PC anti-loop: detect when an AI PC re-declares the same non-action turn
  # after turn ("¿subimos al círculo?" x N, "voy a calentar el brazo" x N) and
  # force a different concrete action. The system prompt already forbids this,
  # but prompts alone weren't enough — so we compare the bot's last two
  # narrations and, on a near-duplicate, stitch a hard nudge onto the instruction.
  # Jaccard similarity over word sets (>0.75) catches verbatim repeats and light
  # reformulations without firing on legitimately related turns.
  @pc_stopwords MapSet.new(
                  ~w(el la los las un una unos unas de del a al en y o u que se su sus es son por para con sin como mas pero si no ya yo tu él me te le nos os les esto eso aque mi tu sus nuestrouestra al acabo apenas cuando donde mientras tras etecera)
                )
  @pc_repeat_threshold 0.75

  @spec with_pc_anti_loop(term(), String.t(), String.t()) :: String.t()
  def with_pc_anti_loop(game_id, current, base_instruction) do
    case pc_repetition(game_id, current) do
      {:repeating, last_text} ->
        Logger.info(
          "dragonex game #{game_id} PC #{current} stuck in a loop — injecting anti-loop nudge"
        )

        pc_anti_loop_nudge(last_text, base_instruction)

      :ok ->
        base_instruction
    end
  end

  # Pull the last two :narration events by this actor and flag a repeat if the
  # texts are highly similar. Ignores tool-only turns (no narration) and the
  # very first turn (nothing to compare against).
  defp pc_repetition(game_id, current) do
    texts =
      game_id
      |> Games.recent_events(40)
      |> Enum.filter(fn e -> e.type == :narration and e.actor == current end)
      |> Enum.map(fn e -> e.payload["text"] || "" end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(2)

    case texts do
      [a, b] when is_binary(a) and is_binary(b) ->
        if text_similarity(a, b) >= @pc_repeat_threshold, do: {:repeating, a}, else: :ok

      _ ->
        :ok
    end
  end

  defp pc_anti_loop_nudge(last_text, base) do
    snippet = String.slice(String.trim(last_text), 0, 140)

    "⚠️ ANTIBUCLE DETECTADO ⚠️ En tu último turno dijiste prácticamente lo mismo: «#{snippet}». " <>
      "ESTÁ PROHIBIDO repetir o reformular esa misma intención. " <>
      "ESTE TURNO haz algo DISTINTO y LOCAL, en ESTA escena: un detalle que no hayas mencionado, " <>
      "una frase nueva a un compañero o PNJ, inspeccionar lo que ya está delante, o " <>
      "ability_check(\"<tu nombre>\", \"<skill (stealth, persuasion…) o str|dex|int|wis|cha>\", <DC>) si hay riesgo real. " <>
      "PROHIBIDO: marcharte, viajar, cruzar umbrales, abrir lo que el humano pidió no abrir, " <>
      "ejecutar un plan de varios pasos, o narrar que otro PC te sigue. Responde en castellano.\n\n" <>
      base
  end

  # ===========================================================================
  # Shared text-analysis helpers
  # ===========================================================================

  # Jaccard similarity over normalized word sets. Robust to punctuation,
  # accents, and casing; stopwords are dropped so short function words don't
  # inflate the score. Returns 0.0 for empty inputs.
  defp text_similarity(a, b) do
    set_a = tokenize(a)
    set_b = tokenize(b)

    if MapSet.size(set_a) == 0 or MapSet.size(set_b) == 0 do
      0.0
    else
      inter = MapSet.intersection(set_a, set_b) |> MapSet.size()
      union = MapSet.union(set_a, set_b) |> MapSet.size()
      inter / union
    end
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&MapSet.member?(@pc_stopwords, &1))
    |> MapSet.new()
  end
end
