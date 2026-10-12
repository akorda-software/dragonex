defmodule Dragonex.TextPCNameFormsTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat

  @sample File.read!(Path.expand("../fixtures/narration/dm_sira_short_name.txt", __DIR__))
  @sira "Sira de la Chispa"
  @pcs [@sira, "Iria del Alba"]

  test "the real opening removes the short-name action inside cuando and preserves the world and NPC" do
    clean = Text.scrub(@sample, "dm", pc_names: [@sira])
    refute clean =~ "deja caer"
    assert clean =~ "El cuarto se llena de un leve olor a ozono."
    assert clean =~ "muchacho pálido del gremio de barqueros"
    assert clean =~ "La señora del muelle lo pidió"
    assert Text.scrub(clean, "dm", pc_names: [@sira]) == clean
  end

  test "the real actor retains its short-name actions and attributed voice" do
    raw = "Sira cierra los ojos. «Yo quiero estudiar la reserva», dice Sira."
    assert Text.scrub(raw, @sira, pc_names: @pcs) == raw
  end

  test "a PC cannot supply a foreign short-name gesture or an implicit reply" do
    raw = "Iria cierra el libro. Sira alza una ceja. «Todos aceptamos». La sala está en calma."
    clean = Text.scrub(raw, "Iria del Alba", pc_names: @pcs)
    assert clean =~ "Iria cierra el libro"
    assert clean =~ "La sala está en calma"
    refute clean =~ "Sira alza"
    refute clean =~ "Todos aceptamos"
  end

  test "a short name shared by a PC and a registered NPC does not infer ownership" do
    names = [@sira, "Sira del Muelle"]
    raw = "Sira alza una ceja. «Esperad aquí», dice Sira. Sira del Muelle abre la puerta."
    assert Text.scrub(raw, "dm", pc_names: [@sira], character_names: names) == raw

    clean =
      Text.scrub(@sira <> " alza una ceja. Sira del Muelle abre la puerta.", "dm",
        pc_names: [@sira],
        character_names: names
      )

    refute clean =~ @sira <> " alza"
    assert clean =~ "Sira del Muelle abre"
  end

  test "a shared PC first name is not assigned to the wrong participant" do
    names = [@sira, "Sira del Río"]
    raw = "Sira cierra el libro. «Yo espero», dice Sira."
    assert Text.scrub(raw, @sira, pc_names: names) == raw
    assert Text.scrub(raw, "dm", pc_names: names) == raw

    clean =
      Text.scrub("Sira del Río alza una ceja. La sala está en calma.", @sira, pc_names: names)

    refute clean =~ "alza"
    assert clean =~ "La sala está en calma"
  end

  test "complete speaker names take precedence over a different PC with the same prefix" do
    raw = "«Yo viajaría mañana», dice Lyra del Mar. «Todos partimos», dice Lyra."
    clean = Text.scrub(raw, "Lyra del Mar", pc_names: ["Lyra", "Lyra del Mar"])
    assert clean =~ "Yo viajaría mañana"
    refute clean =~ "Todos partimos"
  end

  test "leading self-name formatting cannot erase another PC's complete name" do
    raw = "Lyra del Mar alza una ceja. La puerta espera."
    clean = Text.scrub(raw, "Lyra", pc_names: ["Lyra", "Lyra del Mar"])
    refute clean =~ "alza"
    assert clean =~ "La puerta espera"
  end

  test "the guardrail detector shares short names and registered name ambiguity" do
    assert Text.dm_puppets_pc?("Cuando Sira deja el libro, la puerta cruje.", @pcs)
    assert Text.dm_puppets_pc?("Éowyn alza una ceja.", ["Éowyn del Bosque"])

    refute Text.dm_puppets_pc?("Sira alza una ceja.", [@sira], [@sira, "Sira del Muelle"])

    refute Text.dm_puppets_pc?("Lyra del Muelle abre la puerta.", ["Lyra"], [
             "Lyra",
             "Lyra del Muelle"
           ])

    refute Text.dm_puppets_pc?("Sira está herida mientras Sena abre la puerta.", @pcs)
  end

  test "a registered NPC with a PC-name prefix keeps its attributed voice" do
    raw = "«Volved al amanecer», dice Lyra del Muelle. «Aceptamos», dice Lyra."

    clean =
      Text.scrub(raw, "dm", pc_names: ["Lyra"], character_names: ["Lyra", "Lyra del Muelle"])

    assert clean =~ "Volved al amanecer"
    refute clean =~ "Aceptamos"
  end

  test "a subordinate foreign action is cut locally for DM and PC without taking an NPC action" do
    for actor <- ["dm", "Iria del Alba"] do
      raw = "El aire vibra mientras Sira conjura fuego, y Sena cierra la puerta."
      clean = Text.scrub(raw, actor, pc_names: @pcs, character_names: @pcs ++ ["Sena"])
      refute clean =~ "conjura"
      assert clean =~ "El aire vibra"
      assert clean =~ "Sena cierra la puerta"
    end
  end

  test "passive short-name states, questions and actions of a following NPC stay untouched" do
    for raw <- [
          "Sira está herida mientras Sena abre la puerta.",
          "Sena cierra la puerta junto a Sira.",
          "«Sira, ¿prefieres descansar?»",
          "El aire vibra mientras Sira permanece sentada."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @pcs, character_names: @pcs ++ ["Sena"]) == raw
    end
  end

  test "streaming uses the same naming context and bounds the short-name subordinate" do
    for tail <- ["deja", "deja caer la última chispa", "deja caer la última chispa."] do
      raw = "El aire vibra cuando Sira #{tail}"
      clean = Chat.live_shown(raw, "dm", @pcs, @pcs ++ ["Sena"])
      refute clean =~ "Sira deja"
      assert clean =~ "El aire vibra"
      assert Chat.live_shown(raw, @sira, @pcs, @pcs ++ ["Sena"]) == raw
    end
  end

  test "Unicode short names are bounded without matching inside another name" do
    pcs = ["Éowyn del Bosque"]
    clean = Text.scrub("Éowyn alza una ceja. La puerta espera.", "dm", pc_names: pcs)
    refute clean =~ "alza"
    assert clean =~ "La puerta espera"
    raw = "SuperÉowyn alza una ceja."
    assert Text.scrub(raw, "dm", pc_names: pcs) == raw
  end
end
