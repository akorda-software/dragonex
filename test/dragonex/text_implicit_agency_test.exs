defmodule Dragonex.TextImplicitAgencyTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat

  @pcs ["Sylvi del Roble", "Lyra", "Vex"]
  @sample File.read!(Path.expand("../fixtures/narration/dm_roble_collective_move.txt", __DIR__))

  test "the real opening removes the assumed approach without losing the bird or pendant" do
    for actor <- ["dm", "Lyra"] do
      clean = Text.scrub(@sample, actor, pc_names: @pcs)
      refute clean =~ "al acercaros"
      assert clean =~ "El arrendajo os espera"
      assert clean =~ "el destello verdoso se revela por fin"
      assert clean =~ "un pequeño colgante de piedra"
      assert clean =~ "El pájaro lo picotea con suavidad"
      assert Text.scrub(clean, actor, pc_names: @pcs) == clean
    end
  end

  test "affirmed temporal plural movement loses only its bounded trigger and destination" do
    for movement <- [
          "Al acercaros al roble,",
          "Al adentraros en el jardín,",
          "Al dirigiros hacia la ventana,",
          "Al alejarnos de la puerta,",
          "Al marcharnos de la posada,",
          "Al apartarnos del sendero,"
        ],
        actor <- ["dm", "Lyra"] do
      raw = movement <> " el pájaro canta. La ventana sigue cerrada."

      assert Text.scrub(raw, actor, pc_names: @pcs) ==
               "El pájaro canta. La ventana sigue cerrada."

      assert Text.puppets_pc?(raw, actor, @pcs)
      assert Text.dm_puppets_pc?(raw, @pcs)
    end
  end

  test "NPC speech, incomplete quotations, questions and conditional invitations are preserved" do
    for raw <- [
          "Sena dice: «Al acercaros al roble, veréis el nido».",
          "«Al acercaros al roble, veréis el nido», dice Sena.",
          "Sena dice: «Al acercaros al roble",
          "¿Al acercaros al roble, buscaríais el nido?",
          "¿Al acercaros al roble,",
          "Si decidís salir, al acercaros al roble veréis el nido.",
          "Podríais mirar el nido al acercaros al roble.",
          "Propongo examinar el nido al acercarnos al roble.",
          "El arrendajo canta al acercarse al roble.",
          "Al caer la lluvia, el roble se oscurece."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @pcs, character_names: @pcs ++ ["Sena"]) == raw
      refute Text.puppets_pc?(raw, "dm", @pcs, @pcs ++ ["Sena"])
      refute Text.dm_puppets_pc?(raw, @pcs, @pcs ++ ["Sena"])
    end
  end

  test "a completed NPC quotation does not shelter the next assumed group approach" do
    raw = "Sena pregunta: «¿Esperáis aquí?» Al acercaros al roble, el pájaro canta."
    clean = Text.scrub(raw, "dm", pc_names: @pcs, character_names: @pcs ++ ["Sena"])
    assert clean == "Sena pregunta: «¿Esperáis aquí?» El pájaro canta."
    assert Text.puppets_pc?(raw, "dm", @pcs, @pcs ++ ["Sena"])
  end

  test "questions and conditional language inside NPC speech do not shelter movement outside it" do
    for quote <- ["¿Esperáis aquí?", "Si queréis, esperad aquí"] do
      raw = "Sena dice: «#{quote}», y al acercaros al roble, el pájaro canta."
      clean = Text.scrub(raw, "dm", pc_names: @pcs, character_names: @pcs ++ ["Sena"])
      assert clean == "Sena dice: «#{quote}», y el pájaro canta."
      assert Text.puppets_pc?(raw, "dm", @pcs, @pcs ++ ["Sena"])
      assert Text.dm_puppets_pc?(raw, @pcs, @pcs ++ ["Sena"])
    end
  end

  test "a solo acting PC and the narrator's singular movement keep their own actions" do
    raw = "Al acercarnos al roble, el pájaro canta."
    assert Text.scrub(raw, "Lyra", pc_names: ["Lyra"]) == raw
    refute Text.puppets_pc?(raw, "Lyra", ["Lyra"])
    assert Text.scrub(raw, "dm") == raw
    own = "Al acercarme al roble, veo el nido."
    assert Text.scrub(own, "Lyra", pc_names: @pcs) == own
  end

  test "partial streaming cannot expose the assumed plural movement" do
    for tail <- ["al acercaros", "al acercaros al roble", "al acercaros al roble,"] do
      raw = "El pájaro espera, y " <> tail
      assert Chat.live_shown(raw, "dm", @pcs) == "El pájaro espera"
    end

    assert Chat.live_shown(@sample, "dm", @pcs) == Text.scrub(@sample, "dm", pc_names: @pcs)
  end
end
