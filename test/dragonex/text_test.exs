defmodule Dragonex.TextTest do
  @moduledoc """
  `Text.scrub/2` sanitization, focused on the actor self-reference stripping
  added to kill the "LyraLyra levanta..." duplication: a PC bot narrating in
  third person opens with its own name, which the chat card / streaming bubble
  already labels, so the leading name is dropped at the scrub stage.

  Crucially, scrubbing only strips the ACTOR's own name — DM narration that
  merely mentions a PC ("Lyra cae herida", actor "dm") is left intact, because
  the DM is allowed to describe PCs as part of the world.
  """
  use ExUnit.Case, async: true

  alias Dragonex.Text

  describe "scrub/2 self-name stripping" do
    test "strips the actor's own name opening a third-person narration" do
      assert Text.scrub("Lyra levanta la mano y sonríe.", "Lyra") ==
               "Levanta la mano y sonríe."

      assert Text.scrub("Thane desenvaina su espada.", "Thane") ==
               "Desenvaina su espada."
    end

    test "strips variants: em-dash prefix, colon, markdown italic" do
      assert Text.scrub("—Lyra: sonríe con confianza.", "Lyra") ==
               "Sonríe con confianza."

      assert Text.scrub("*Lyra desenfunda su arco.*", "Lyra") ==
               "Desenfunda su arco."

      assert Text.scrub("Lyra, dice: vale.", "Lyra") == "Dice: vale."
    end

    test "does NOT strip a PC name when the actor is the DM" do
      # DM describing a PC is legitimate world narration — the name stays.
      assert Text.scrub("Lyra cae herida por el golpe.", "dm") ==
               "Lyra cae herida por el golpe."
    end

    test "strips a name glued to the next word with NO space (DeepSeek leak)" do
      # The model sometimes emits "Thanedeja apoyado…" (name fused to the verb).
      # We strip the leading name so it doesn't render doubled. Trade-off: a
      # longer real word starting with the name ("Lyranthropo") would also lose
      # the prefix — accepted because PC names (Thane/Vex/Lyra) aren't prefixes
      # of words that actually occur in a Dragonex partida.
      assert Text.scrub("Thanedeja apoyado su escudo contra la pared.", "Thane") ==
               "Deja apoyado su escudo contra la pared."

      assert Text.scrub("Vexse incorpora y guarda la piedra.", "Vex") ==
               "Se incorpora y guarda la piedra."
    end

    test "strips a name wrapped in markdown bold at the start" do
      # The most common DeepSeek leak in the wild: the name in **bold** glued to
      # the verb. The closing `**` used to defeat the strip.
      assert Text.scrub("**Thane**alza el mapa y lo dobla.", "Thane") ==
               "Alza el mapa y lo dobla."

      assert Text.scrub("**Thane** deja el pergamino sobre la mesa.", "Thane") ==
               "Deja el pergamino sobre la mesa."

      assert Text.scrub("*Lyra*se acerca al círculo.", "Lyra") ==
               "Se acerca al círculo."
    end

    test "does NOT strip a name that is a proper-noun prefix when followed by a space" do
      # Word-boundary safe when the separator is present: "Lyranthropo" alone is
      # ambiguous, but when the name is followed by a SPACE we keep the original
      # behaviour (only the fused-no-space form is treated as the leak).
      assert Text.scrub("Lyra observa el altar.", "Lyra") == "Observa el altar."
    end

    test "leaves narration that doesn't start with the name untouched" do
      assert Text.scrub("Levanto la mano y conjuro fuego.", "Lyra") ==
               "Levanto la mano y conjuro fuego."

      assert Text.scrub("—Bastante vivo, ¿no?", "Lyra") == "—Bastante vivo, ¿no?"
    end

    test "scrub/1 (no actor) never strips a leading name" do
      # Backward compatible: callers that don't pass an actor keep old behaviour.
      assert Text.scrub("Lyra levanta la mano.") == "Lyra levanta la mano."
    end
  end

  describe "scrub/2 still does the rest of its job" do
    test "strips leaked tags AND the self-name together" do
      # The model opened with a history tag it imitated, then its own name.
      assert Text.scrub("[Lyra]: Lyra lanza un firebolt.", "Lyra") ==
               "Lanza un firebolt."
    end

    test "strips inline HP leaks regardless of actor" do
      assert Text.scrub("El goblin queda en 3/7 pg.", "dm") =~ "El goblin queda en"
      refute Text.scrub("El goblin queda en 3/7 pg.", "dm") =~ "3/7"
    end

    test "strips bare HP and CA stats the model leaks" do
      # "7 PG" / "10 hp" bare (no X/Y), plus armor class.
      refute Text.scrub("El esqueleto tiene 7 pg.", "dm") =~ "7 pg"
      refute Text.scrub("Tiene 10 hp.", "Thane") =~ "10 hp"
      refute Text.scrub("Su CA es 15.", "dm") =~ "CA es 15"
      refute Text.scrub("Clase de Armadura 13.", "dm") =~ "13"
      # X de los Y puntos de vida originales.
      refute Text.scrub("Le quedan 1 de los 7 puntos de vida originales.", "dm") =~ "1 de los 7"
      refute Text.scrub("Baja a 5 puntos de golpe.", "dm") =~ "5 puntos de golpe"
    end

    test "does NOT strip lore numbers that aren't stats" do
      # "15 de oro" (gold), "3 puertas" (doors), lowercase "ca" inside words.
      assert Text.scrub("Encuentras 15 monedas de oro.", "dm") =~ "15 monedas"
      assert Text.scrub("Ves 3 puertas al norte.", "dm") =~ "3 puertas"
      assert Text.scrub("La casa está al caer.", "dm") =~ "casa"
    end

    test "drops a narrated tool-call line leaking the engine dice syntax" do
      # The model sometimes emits a half-formed tool call as prose, mirroring the
      # shared history's "[🎲 Vex] ataque ... d20:14" format.
      assert Text.scrub("Vexataque a Golem de entrenamiento con shortbow d20: +5 vs", "Vex") == ""
      # A real narration line that mentions a die but isn't a tool leak stays.
      assert Text.scrub("Recuerdo haber tirado un d20 en otra vida.", "Vex") =~ "d20"
    end

    test "strips tool invocations the model writes into prose" do
      # Function-like leaks (the meta-phrase scrub also removes the surrounding
      # "Lo materializo…" wrapper, which is exactly what we want).
      assert Text.scrub("Lo materializo: establish_fact(\"Vex propone ir a la taberna\").", "dm") ==
               ""

      assert Text.scrub("Uso spawn_monster(\"goblin\", \"g1\") para la emboscada.", "dm") ==
               "Uso para la emboscada."

      assert Text.scrub("Uso grant_xp(\"Thane\", 300) tras el combate.", "dm") ==
               "Uso tras el combate."

      # Bracketed-tag leaks (the surrounding `**` bold markers stay as orphans;
      # that's a minor cosmetic we accept — the important thing is the fake tool
      # tag itself is gone, not rendered to the player as an "action").
      assert Text.scrub("Bien. **[Establecer hecho: Thane aceptó la misión.]** Y ahora...", "dm") ==
               "Bien. Y ahora..."
    end

    test "strips DM fourth-wall / meta phrases" do
      assert Text.scrub("La escena se resetea. El grupo avanza.", "dm") =~ "El grupo avanza."
      refute Text.scrub("La escena se resetea. El grupo avanza.", "dm") =~ "resetea"
      assert Text.scrub("Lo materializo en el mundo para que sea oficial.", "dm") == ""
      assert Text.scrub("Como DM yo decido que llueve.", "dm") == ""
    end

    test "strips mid-prose [DM]: tags (not only leading)" do
      out =
        Text.scrub(
          "El pastor calla. [DM]: El pastor se levanta y señala la puerta.",
          "dm"
        )

      refute out =~ "[DM]"
      assert out =~ "El pastor se levanta"
    end

    test "cleans empty bold shells left after stripping HP/CA" do
      # Playtest leftovers: model wrote **Name: 7 HP** → strip HP → **Name: **
      out1 = Text.scrub("El sabueso cae. **Sabueso de Práctica: 7 HP** Fin.", "dm")
      refute out1 =~ "**"
      refute out1 =~ "7 HP"
      assert out1 =~ "El sabueso cae"

      out2 = Text.scrub("Rhogar recuperado por completo **12/12 HP**.", "dm")
      refute out2 =~ "12/12"
      refute out2 =~ "**"

      out3 = Text.scrub("Lyra queda con **1 de 6 HP**.", "dm")
      refute out3 =~ "HP"
      refute out3 =~ ~r/\b1 de\b/
    end

    test "strips English (AC/HP) stat leaks and parenthesised stat blocks" do
      # The DM dropped an English stat line straight into prose.
      refute Text.scrub(
               "Aparece un espinodemonio de prueba (AC 12, HP 13, daño 1d4+2 con tridente).",
               "dm"
             ) =~
               "AC 12"

      # The whole parenthesis is gone.
      refute Text.scrub("Aparece un espinodemonio de prueba (AC 12, HP 13).", "dm") =~ "("
      # Bare English AC/HP in a sentence.
      refute Text.scrub("Su AC es 15 y tiene HP 20.", "dm") =~ "AC"
    end

    test "strips NdM dice notation leaking into prose" do
      refute Text.scrub("El arma causa 1d4+2 de daño.", "dm") =~ "1d4"
      refute Text.scrub("Golpea por 2d6.", "dm") =~ "2d6"
      # A standalone "d20" without a count is left to the engine-signature
      # pattern; the dice-notation scrub only matches NdM with a count.
      assert Text.scrub("Sacó un d20 natural.", "dm") =~ "d20"
    end

    test "unwraps leftover markdown italics in prose" do
      out = Text.scrub("Se inclina. *Deja caer un trozo de pan.* Sigue hablando.", "dm")
      refute out =~ "*"
      assert out =~ "Deja caer un trozo de pan"
    end

    test "strips orphan asterisks and meta chequeo lines" do
      out = Text.scrub("hacia la barra.* —Buen hombre.", "dm")
      refute out =~ "*"
      assert out =~ "Buen hombre"

      meta = Text.scrub("El éxito del chequeo le devuelve la memoria. El frío seca.", "Lyra")
      refute meta =~ "éxito del chequeo"
      assert meta =~ "El frío seca"
    end

    test "strips DM puppet clauses that start with a PC action" do
      out =
        Text.scrub(
          "Lyra se acerca al tablón y lee el aviso. El fuego crepita en el hogar.",
          "dm",
          pc_names: ["Lyra", "Thane"]
        )

      refute out =~ ~r/se acerca/i
      assert out =~ "El fuego crepita"

      kept = Text.scrub("Lyra está herida junto a la valla.", "dm", pc_names: ["Lyra"])
      assert kept =~ "Lyra está herida"

      kept2 = Text.scrub("Lyra cae herida por el golpe.", "dm", pc_names: ["Lyra"])
      assert kept2 =~ "Lyra cae herida"

      kept3 =
        Text.scrub(
          "Junto a Lyra, el tabernero abre la puerta trasera.",
          "dm",
          pc_names: ["Lyra"]
        )

      assert kept3 =~ "el tabernero abre"
    end

    test "strips time-skip and NPC voice from a PC beat" do
      skip =
        Text.scrub(
          "Asiento. Media hora después llegáis a la torre. El frío muerde.",
          "Thane"
        )

      refute skip =~ ~r/media hora/i
      assert skip =~ "El frío muerde"

      voice =
        Text.scrub(
          "Me acerco a la barra. —Pasad al fondo —dice el tabernero. Espero su gesto.",
          "Thane"
        )

      refute voice =~ "dice el tabernero"
      assert voice =~ "Me acerco a la barra"
      assert voice =~ "Espero su gesto"

      own = Text.scrub("—¿Qué se cuece? —pregunto al posadero.", "Thane")
      assert own =~ "¿Qué se cuece?"

      borin =
        Text.scrub(
          "Dejo una moneda. El posadero baja la voz: \"Raro, anoche pasaron dos encapuchados.\" Espero.",
          "Thane"
        )

      refute borin =~ "encapuchados"
      assert borin =~ "Dejo una moneda"
    end

    test "cuts NPC voice from a run-on clause without a period" do
      out =
        Text.scrub(
          "Me acerco al posadero y le pregunto qué se cuece y el posadero baja la voz: \"Raro, anteanoche dos tipos preguntaron por la torre\" mientras dejo la moneda.",
          "Thane"
        )

      refute out =~ "encapuchados"
      refute out =~ "anteanoche"
      refute out =~ "baja la voz"
      assert out =~ "Me acerco al posadero"
      assert out =~ "pregunto qué se cuece"
    end

    test "cuts time-skip from a run-on clause and keeps the prefix" do
      out =
        Text.scrub("Asiento y media hora después llegáis a la torre y el frío muerde", "Thane")

      refute out =~ ~r/media hora/i
      assert out =~ "Asiento"
    end

    test "keeps the actor's own quoted question" do
      own = Text.scrub("—¿Qué se cuece? —pregunto.", "Thane")
      assert own =~ "¿Qué se cuece?"
      assert own =~ "pregunto"
    end

    test "strips mid-prose history headers" do
      out =
        Text.scrub(
          "El pergamino pesa. [R2 · Turno de Thane]: ¿Lo abres? El sello cruje.",
          "dm"
        )

      refute out =~ "R2"
      refute out =~ "Turno de Thane"
      assert out =~ "¿Lo abres?"
      assert out =~ "El sello cruje"

      out2 =
        Text.scrub(
          "La puerta cede. [→ Thane decide] Un golpe sordo.",
          "dm"
        )

      refute out2 =~ "decide"
      refute out2 =~ "→"
      assert out2 =~ "La puerta cede"
      assert out2 =~ "Un golpe sordo"
    end

    test "strips a name fused to chequeo/ataque" do
      out = Text.scrub("Lyrachequeo de Inteligencia falla en el aire.", "Lyra")
      refute out =~ "Lyrachequeo"
      assert out =~ ~r/chequeo de Inteligencia/i
    end

    test "addressed_pc detects a question to a named human" do
      assert Text.addressed_pc("Thane, el sello espera. ¿Lo abres?", ["Thane", "Lyra"]) ==
               {:named, "Thane"}

      assert Text.addressed_pc("¿Lo abres?", ["Thane"]) == :question
      assert Text.addressed_pc("Ábrelo tú, si quieres.", ["Thane"]) == :question
      assert Text.addressed_pc("El fuego crepita en el hogar.", ["Thane"]) == nil
      assert Text.addressed_pc("Thane, pasa al fondo.", ["Thane"]) == nil
    end

    test "cuts a shouted NPC line from a PC beat" do
      out =
        Text.scrub(
          "El acero silba. El hombre saca una daga y el enano Borin se agacha tras la barra gritando: —¡Cuidado!",
          "Thane"
        )

      refute out =~ "Cuidado"
      refute out =~ "gritando"
      assert out =~ "El acero silba"
    end

    test "strips solo execution from an AI PC when a human is at the table" do
      out =
        Text.scrub(
          "Se acerca a la barra. Desliza la uña bajo el lacre y despliega el pergamino. ¿Qué opinas, Thane?",
          "Lyra",
          wait_for_human: true
        )

      refute out =~ "despliega"
      refute out =~ "lacre"
      assert out =~ "Se acerca a la barra"
      assert out =~ "¿Qué opinas, Thane?"

      kept =
        Text.scrub(
          "Desliza la uña bajo el lacre y despliega el pergamino.",
          "Lyra"
        )

      assert kept =~ "despliega"
    end

    test "strips an English possessive glued to the actor" do
      assert Text.scrub("Thane's hand cierra en torno a la empuñadura.", "Thane") ==
               "Cierra en torno a la empuñadura."
    end

    test "strips a name fused to Se/Me with a capital S" do
      assert Text.scrub("ThaneSe levanta de la mesa.", "Thane") == "Se levanta de la mesa."
      assert Text.scrub("LyraSe acerca a la barra.", "Lyra") == "Se acerca a la barra."
    end

    test "sanitize_utf8 strips stray lead bytes that would break Jason" do
      # 0xC2 is a 2-byte UTF-8 lead; without its continuation byte it is invalid
      # and crashes Jason.encode! — exactly the byte that wedged partida 108
      # (every beat failed with {:model_request_failed, %Jason.EncodeError{...}}).
      assert Text.sanitize_utf8(<<"a", 0xC2, "b">>) == "ab"
      assert Text.sanitize_utf8(<<"palabra ", 0xC2, "…">>) =~ "palabra"

      # Valid text is unchanged.
      assert Text.sanitize_utf8("La sombra acechante flota.") == "La sombra acechante flota."

      # Multi-byte chars (accents, ñ, middle dot) are preserved.
      assert Text.sanitize_utf8("café Ñandú · …") == "café Ñandú · …"
    end
  end
end
