defmodule Dragonex.TextGroupDecisionTest do
  use ExUnit.Case, async: true
  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat
  @pcs ["Mara de la Bruma", "Lyra", "Vex"]
  @decision File.read!(
              Path.expand("../fixtures/narration/dm_granero_group_decision.txt", __DIR__)
            )
            |> String.trim()
  @gesture File.read!(
             Path.expand("../fixtures/narration/mara_granero_plural_gesture.txt", __DIR__)
           )
           |> String.trim()

  test "the real DM closing cannot declare that the group already decided" do
    clean = Text.scrub(@decision, "dm", pc_names: @pcs)
    refute clean =~ "La decisión queda tomada"
    assert clean =~ "la posadera sacude un trapo"
    assert clean =~ "su consejo está a punto de ser pedido"
    assert Text.dm_puppets_pc?(@decision, @pcs)
    assert Text.puppets_pc?(@decision, "dm", @pcs)
    assert Text.scrub(clean, "dm", pc_names: @pcs) == clean
  end

  test "the human's narration preserves her declaration without making companions exchange looks" do
    clean = Text.scrub(@gesture, "Mara de la Bruma", pc_names: @pcs)
    refute clean =~ "os miráis"
    assert clean =~ "Te quedas junto a la ventana"
    assert clean =~ "—Lyra, Vex, ¿preferís pasear"
    assert Text.puppets_pc?(@gesture, "Mara de la Bruma", @pcs)
    assert Text.scrub(clean, "Mara de la Bruma", pc_names: @pcs) == clean
  end

  test "bounded passive group decisions are cut for the DM and a companion" do
    for actor <- ["dm", "Lyra"],
        decision <- [
          "La decisión queda tomada entre vosotros: iremos al pueblo.",
          "La decisión ya está tomada entre vosotras.",
          "La decisión ha quedado tomada entre vosotros sin debate."
        ] do
      assert Text.scrub(decision <> " La puerta sigue cerrada.", actor, pc_names: @pcs) ==
               "La puerta sigue cerrada."
    end
  end

  test "NPC agreements, questions, plans and quoted assertions remain intact" do
    for raw <- [
          "La decisión queda tomada entre los guardias: se irán al pueblo.",
          "¿La decisión queda tomada entre vosotros?",
          "Si la decisión queda tomada entre vosotros, avisad a Sena.",
          "Sena dice: «La decisión queda tomada entre vosotros».",
          "Sena dice: «La decisión queda tomada entre vosotros",
          "¿Os miráis un momento?",
          "Propongo que nos miramos un momento antes de hablar.",
          "Sena dice: «Os miráis un momento cuando queráis».",
          "Miro a Lyra y espero su respuesta."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @pcs) == raw
      refute Text.puppets_pc?(raw, "dm", @pcs)
      refute Text.dm_puppets_pc?(raw, @pcs)
    end

    raw = "El patio está en calma ."
    assert Text.scrub(raw, "dm", pc_names: @pcs) == "El patio está en calma."
    refute Text.puppets_pc?(raw, "dm", @pcs)
    refute Text.dm_puppets_pc?(raw, @pcs)
  end

  test "the end of an NPC quote does not shelter the following consensus" do
    raw =
      "Sena dice: «¡Esperad!» La decisión queda tomada entre vosotros. La puerta sigue cerrada."

    clean = Text.scrub(raw, "dm", pc_names: @pcs)
    assert clean == "Sena dice: «¡Esperad!» La puerta sigue cerrada."
    assert Text.dm_puppets_pc?(raw, @pcs)
  end

  test "a solo PC retains its own collective wording without borrowing another PC" do
    for raw <- ["Nos miramos un momento.", "La decisión queda tomada entre vosotros."] do
      assert Text.scrub(raw, "Lyra", pc_names: ["Lyra"]) == raw
      assert Text.scrub(raw, "dm") == raw
    end
  end

  test "streaming hides the committed consensus and preserves the surroundings" do
    assert Chat.live_shown("La decisión queda tomada entre vosotros", "dm", @pcs) == ""
    assert Chat.live_shown(@decision, "dm", @pcs) == Text.scrub(@decision, "dm", pc_names: @pcs)
    assert Chat.live_shown("Os miráis un momento", "dm", @pcs) == ""
  end
end
