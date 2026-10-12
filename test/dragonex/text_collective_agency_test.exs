defmodule Dragonex.TextCollectiveAgencyTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat

  @pcs ["Sylvi del Roble", "Lyra", "Vex"]
  @sample File.read!(Path.expand("../fixtures/narration/dm_roble_collective_move.txt", __DIR__))
  @scene File.read!(Path.expand("../fixtures/narration/scene_roble_collective_move.txt", __DIR__))

  test "the real opening removes the collective crossing and keeps the bird and object" do
    clean = Text.scrub(@sample, "dm", pc_names: @pcs)
    refute clean =~ "El grupo cruza el umbral"
    refute clean =~ "vuestros pasos hasta el pie"
    assert clean =~ "El arrendajo os espera"
    assert clean =~ "un pequeño colgante de piedra tallado en forma de hoja de roble"
    assert clean =~ "El pájaro lo picotea con suavidad"
    assert Text.dm_puppets_pc?(@sample, @pcs)
    assert Text.dm_puppets_pc?(@scene, @pcs)
    assert Text.scrub(clean, "dm", pc_names: @pcs) == clean
  end

  test "explicit party subjects and committed plural movement cannot act for other PCs" do
    actions = [
      "El grupo cruza el umbral.",
      "**El grupo** cruza el umbral.",
      "La party avanza hacia el bosque.",
      "El equipo se acerca al altar.",
      "Los aventureros aceptan el encargo.",
      "Vosotros cruzáis el puente.",
      "Decidís salir de la sala.",
      "Os acercáis al roble.",
      "Nos acercamos al roble.",
      "Decidimos aceptar el encargo.",
      "Salimos de la posada."
    ]

    for actor <- ["dm", "Lyra"], action <- actions do
      raw = action <> " El pájaro canta en la ventana."
      assert Text.scrub(raw, actor, pc_names: @pcs) == "El pájaro canta en la ventana."
      assert Text.dm_puppets_pc?(raw, @pcs)
    end
  end

  test "NPC groups, passive consequences, conditional plans and invitations stay intact" do
    for raw <- [
          "El grupo de guardias cruza el puente.",
          "Los aventureros del Concejo aceptan el encargo.",
          "El grupo está herido junto al fuego.",
          "El grupo cae al suelo por la sacudida.",
          "Vosotros veis el roble desde la ventana.",
          "El grupo puede cruzar el puente si quiere.",
          "Si el grupo cruza el umbral, encontrará el jardín.",
          "¿Decidís salir de la sala?",
          "¿El grupo cruza el puente?",
          "Propongo que salgamos de la sala. ¿Qué os parece?"
        ],
        actor <- ["dm", "Lyra"] do
      assert Text.scrub(raw, actor, pc_names: @pcs) == raw
      refute Text.dm_puppets_pc?(raw, @pcs)
    end

    for raw <- ["Sena dice: «Vosotros cruzáis cuando queráis».", "«Decidís vosotros», dice Sena."] do
      assert Text.scrub(raw, "dm", pc_names: @pcs) == raw
      refute Text.dm_puppets_pc?(raw, @pcs)
    end
  end

  test "a PC keeps a singular action and a solo PC does not borrow another character" do
    assert Text.scrub("Cruzo hasta la ventana.", "Lyra", pc_names: @pcs) ==
             "Cruzo hasta la ventana."

    assert Text.scrub("Salimos de la sala.", "Lyra", pc_names: ["Lyra"]) == "Salimos de la sala."
    assert Text.scrub("El grupo avanza.", "dm") == "El grupo avanza."
    assert Text.puppets_pc?("Lyra se acerca al roble.", "dm", @pcs)
    refute Text.puppets_pc?("Lyra se acerca al roble.", "Lyra", @pcs)
  end

  test "streaming hides an explicit collective action once its predicate is known" do
    for tail <- ["cruza", "cruza el umbral", "cruza el umbral."] do
      assert Chat.live_shown("El grupo " <> tail, "dm", @pcs) == ""
    end

    assert Chat.live_shown(@sample, "dm", @pcs) == Text.scrub(@sample, "dm", pc_names: @pcs)
  end

  test "a completed NPC quotation does not shelter the following collective action" do
    raw = "Sena dice: «¡Esperad!» El grupo cruza el umbral. El roble se mece."
    clean = Text.scrub(raw, "dm", pc_names: @pcs, character_names: @pcs ++ ["Sena"])
    assert clean =~ "Sena dice: «¡Esperad!»"
    refute clean =~ "El grupo cruza"
    assert clean =~ "El roble se mece"
  end
end
