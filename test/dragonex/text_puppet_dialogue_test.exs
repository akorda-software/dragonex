defmodule Dragonex.TextPuppetDialogueTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text

  @sample File.read!(Path.expand("../fixtures/narration/dm_tavern_puppet.txt", __DIR__))
  @pcs ["Lyra", "Vex", "Thane"]
  @six_sample File.read!(Path.expand("../fixtures/narration/dm_six_party_puppet.txt", __DIR__))
  @six_pcs ["Iria del Alba", "Lyra", "Mara de la Bruma", "Nera del Camino", "Thane", "Vex"]
  @pc_sample File.read!(Path.expand("../fixtures/narration/pc_iria_foreign_gesture.txt", __DIR__))

  test "the real human-PC narration preserves its questions without borrowing a companion gesture" do
    clean = Text.scrub(@pc_sample, "Iria del Alba", pc_names: @six_pcs)
    refute clean =~ "sigue hojeando"
    assert clean =~ "Luego giro la cabeza hacia Lyra."
    assert clean =~ "qué hay en la ruta del molino"
    assert clean =~ "qué te dice lo de las luces"
    assert clean =~ "esperando sus respuestas"
    assert Text.scrub(clean, "Iria del Alba", pc_names: @six_pcs) == clean
  end

  test "a PC keeps its own voice while other named PCs and their implicit speech are removed" do
    raw =
      "Alzo una ceja. «Yo estudiaría el mapa». Vex asiente. «Salgamos ya». La posada está en calma."

    clean = Text.scrub(raw, "Lyra", pc_names: @pcs)
    assert clean =~ "Alzo una ceja"
    assert clean =~ "Yo estudiaría el mapa"
    refute clean =~ "Vex asiente"
    refute clean =~ "Salgamos ya"
    assert clean =~ "La posada está en calma"
  end

  test "explicit foreign-PC speech is removed while the current PC's speech remains" do
    clean =
      Text.scrub("«Mi opinión», dice Lyra. «Todos aceptamos», comenta Vex.", "Lyra",
        pc_names: @pcs
      )

    assert clean =~ "Mi opinión"
    refute clean =~ "Todos aceptamos"
  end

  test "relative actions are cut locally before a comma or sentence end for both DM and PCs" do
    for actor <- ["dm", "Iria del Alba"] do
      clean =
        Text.scrub(
          "Miro hacia Lyra, que sigue hojeando el libro, y pregunto por el sello. Nera del Camino, que afina el arco, está junto a la puerta.",
          actor,
          pc_names: @six_pcs
        )

      refute clean =~ "sigue hojeando"
      refute clean =~ "afina el arco"
      assert clean =~ "Miro hacia Lyra y pregunto por el sello."
      assert clean =~ "Nera del Camino está junto a la puerta."
    end
  end

  test "passive states, invitations and the actor's own relative actions remain" do
    for raw <- [
          "Pregunto a Lyra, que está herida, si prefiere descansar.",
          "Lyra cae herida junto al fuego. Vex permanece junto a la puerta.",
          "«Lyra, ¿quieres estudiar el mapa?»",
          "Se acerca a Vex y le pregunta por el puente."
        ] do
      assert Text.scrub(raw, "Thane", pc_names: @pcs) == raw
    end

    own = "Se acerca a Lyra, que sigue hojeando su libro, y dice: «Mi opinión»."
    assert Text.scrub(own, "Lyra", pc_names: @pcs) == own
  end

  test "a relative PC action cannot absorb a question or a later NPC action" do
    raw = "Miro a Lyra, que está sentada mientras Sena hojea el libro, y pregunto: ¿Qué hacemos?"
    assert Text.scrub(raw, "Thane", pc_names: @pcs) == raw
  end

  test "a foreign PC's passive clause keeps an action performed by a later NPC" do
    for raw <- [
          "Lyra está herida mientras Sena abre la puerta.",
          "Vex permanece junto a Sena, que responde: «Podéis descansar».",
          "Lyra guarda silencio mientras Sena habla."
        ],
        actor <- ["dm", "Thane"] do
      assert Text.scrub(raw, actor, pc_names: @pcs) == raw
      refute Text.dm_puppets_pc?(raw, @pcs)
    end
  end

  test "streaming suppresses the same foreign-PC relative and preserves the following question" do
    for tail <- ["hojeando", "hojeando sus pergaminos", "hojeando sus pergaminos."] do
      raw = "Luego miro hacia Lyra, que sigue #{tail}"
      shown = DragonexWeb.GameLive.Chat.live_shown(raw, "Iria del Alba", @six_pcs)
      refute shown =~ "hojeando"
      assert shown =~ "Luego miro hacia Lyra"
    end

    shown = DragonexWeb.GameLive.Chat.live_shown(@pc_sample, "Iria del Alba", @six_pcs)
    assert shown == Text.scrub(@pc_sample, "Iria del Alba", pc_names: @six_pcs)
  end

  test "escaped compound PC names and leading self names preserve the real actor" do
    names = ["Ana (II)", "Lyra"]

    clean =
      Text.scrub(
        "Ana (II) alza una ceja. Lyra comenta: «Aceptamos». Se prepara para preguntar.",
        "Ana (II)",
        pc_names: names
      )

    assert clean =~ "Alza una ceja"
    refute clean =~ "Aceptamos"
    assert clean =~ "Se prepara para preguntar"
  end

  test "the six-PC live opening removes borrowed dialogue and named preparations" do
    clean = Text.scrub(@six_sample, "dm", pc_names: @six_pcs)
    refute clean =~ "Lyra, la elfa maga, alza"
    refute clean =~ "estrenar estos pergaminos"
    refute clean =~ "Nera del Camino afina"
    assert clean =~ "Mara de la Bruma guarda silencio"
    assert clean =~ "¿Qué hace el grupo?"
    assert Text.scrub(clean, "dm", pc_names: @six_pcs) == clean
  end

  test "a quote with an implicit comment belongs to the preceding removed PC gesture" do
    clean =
      Text.scrub("Lyra alza una ceja. «Partamos ahora.» —comenta. La puerta cruje.", "dm",
        pc_names: @pcs
      )

    refute clean =~ "Partamos"
    refute clean =~ "Lyra alza"
    assert clean =~ "La puerta cruje"
  end

  test "comment attribution distinguishes explicit NPC and PC voices" do
    clean =
      Text.scrub("«Partamos ahora», comenta Lyra. «Volved pronto», comenta Sena.", "dm",
        pc_names: @pcs
      )

    refute clean =~ "Partamos"
    assert clean =~ "«Volved pronto», comenta Sena"

    reply = Text.scrub("Lyra alza una ceja. «Volved pronto», comenta Sena.", "dm", pc_names: @pcs)
    assert reply =~ "«Volved pronto», comenta Sena"
  end

  test "incomplete streamed quotations after a removed PC gesture stay hidden" do
    for quoted <- [
          "«Partamos",
          "«Partamos ahora.»",
          "«Partamos ahora.» —com",
          "«Partamos ahora.» —comenta."
        ] do
      raw = "Lyra alza una ceja. #{quoted}"
      clean = DragonexWeb.GameLive.Chat.live_shown(raw, "dm", @pcs)
      refute clean =~ "Partamos", quoted
    end
  end

  test "PCs retain their own gestures and first-person comments" do
    clean = Text.scrub("Alzo una ceja. «Partamos ahora», comento.", "Lyra", pc_names: @pcs)
    assert clean =~ "Alzo una ceja"
    assert clean =~ "Partamos ahora"
  end

  test "successive unattributed quotations keep the removed PC speaker until an NPC takes over" do
    raw =
      "Lyra alza una ceja. «Partamos ahora.» —comenta. «Tú decides, Iria.» —añade. «Volved pronto», dice Sena. La puerta cruje."

    clean = Text.scrub(raw, "dm", pc_names: @six_pcs)
    refute clean =~ "Partamos"
    refute clean =~ "Tú decides"
    assert clean =~ "«Volved pronto», dice Sena"
    assert clean =~ "La puerta cruje"
  end

  test "new gesture verbs must belong to the named PC rather than an NPC in the same sentence" do
    for raw <- [
          "Lyra está herida mientras Sena alza un farol.",
          "Mara de la Bruma guarda silencio mientras Sena afina su instrumento.",
          "Lyra está sentada junto a Sena, que comenta el aviso."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @six_pcs) == raw
      refute Text.dm_puppets_pc?(raw, @six_pcs)
    end
  end

  test "direct comments and appositive gestures are detected without erasing NPC questions" do
    assert Text.dm_puppets_pc?("Lyra, la elfa maga, alza una ceja.", @pcs)
    assert Text.dm_puppets_pc?("Nera del Camino afina el arco.", @six_pcs)

    refute Text.scrub("Lyra comenta: «Partamos». ¿Qué hace Thane?", "dm", pc_names: @pcs) =~
             "Partamos"

    assert Text.scrub("Sena comenta: «¿Qué hace Thane?»", "dm", pc_names: @pcs) =~ "Sena comenta"
  end

  test "the real tavern opening preserves the NPC but removes invented PC speech and decisions" do
    clean = Text.scrub(@sample, "dm", pc_names: @pcs)
    assert clean =~ "Borin os mira"
    assert clean =~ "el camino no es suyo"
    assert clean =~ "¿Qué hace Thane?"
    refute clean =~ "Lyra deja"
    refute clean =~ "¿Alguien más ha notado"
    refute clean =~ "Vex asiente"
    assert Text.scrub(clean, "dm", pc_names: @pcs) == clean
  end

  test "a PC may narrate their own agreement" do
    assert Text.scrub("Asiento despacio. «Acepto el encargo».", "Vex", pc_names: @pcs) =~
             "Asiento despacio"
  end

  test "explicit quoted speech attributed to a PC is removed" do
    clean = Text.scrub("«Acepto el encargo», dice Lyra. La puerta cruje.", "dm", pc_names: @pcs)
    refute clean =~ "Acepto el encargo"
    assert clean =~ "La puerta cruje"
  end

  test "an NPC quotation and a following passive PC state are preserved" do
    text = "Borin advierte: «No abráis la puerta.» Lyra está herida junto al fuego."
    assert Text.scrub(text, "dm", pc_names: @pcs) == text
  end

  test "a quoted NPC response following a removed PC action is preserved" do
    clean =
      Text.scrub("Lyra se acerca al tablón. «Volved pronto», dice Borin. El fuego crepita.", "dm",
        pc_names: @pcs
      )

    refute clean =~ "Lyra se acerca"
    assert clean =~ "«Volved pronto», dice Borin"
    assert clean =~ "El fuego crepita"
  end

  test "compound PC names are escaped and quoted references remain world narration" do
    clean =
      Text.scrub("Borin dice: «¿Listos?» Ana (II) asiente. El letrero dice «Ana (II)».", "dm",
        pc_names: ["Ana (II)"]
      )

    refute clean =~ "Ana (II) asiente"
    assert clean =~ "El letrero dice «Ana (II)»"
  end
end
