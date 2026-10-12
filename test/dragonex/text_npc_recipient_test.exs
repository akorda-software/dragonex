defmodule Dragonex.TextNPCRecipientTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat

  @pcs ["Mara de la Bruma", "Lyra", "Vex"]
  @sample File.read!(Path.expand("../fixtures/narration/pc_vex_npc_recipient.txt", __DIR__))
          |> String.trim()

  test "the reconstructed delivery keeps the NPC recipient before the PC's closing dialogue dash" do
    assert Text.scrub(@sample, "Vex", pc_names: @pcs, wait_for_human: true) == @sample
    assert Chat.live_shown(@sample, "Vex", @pcs, @pcs ++ ["Posadera"]) == @sample
  end

  test "role objects before a closing dash or the speaker's quote remain in the PC's own voice" do
    for role <- ["la posadera", "el tabernero", "la anciana", "el encapuchado", "la enana"],
        raw <- [
          "—Muchas gracias —digo a #{role}—. Espero su respuesta.",
          "Le entrego el saquito a #{role}: «Aquí tiene sus semillas».",
          "Me quedo junto a #{role}, «Muchas gracias por el pan», digo."
        ] do
      assert Text.scrub(raw, "Vex", pc_names: @pcs) == raw
    end
  end

  test "actual NPC subjects and role speaker labels still lose their foreign speech" do
    for tail <- [
          "La posadera: «Venid al patio».",
          "La posadera levanta un brazo: «Venid al patio».",
          "Me acerco y la posadera levanta un brazo: «Venid al patio».",
          "Me acerco, la posadera levanta un brazo: «Venid al patio».",
          "Me acerco; la posadera levanta un brazo: «Venid al patio»."
        ] do
      raw = "Alzo la jarra. " <> tail
      clean = Text.scrub(raw, "Vex", pc_names: @pcs)
      assert clean =~ "Alzo la jarra."
      refute clean =~ "Venid al patio"
    end
  end

  test "addressing an NPC does not shelter that NPC's later response in the same passage" do
    raw =
      "—Buenas tardes —digo a la posadera—. La posadera baja la voz: «Cerrad la puerta». Me quedo en el patio."

    assert Text.scrub(raw, "Vex", pc_names: @pcs) ==
             "—Buenas tardes —digo a la posadera—. Me quedo en el patio."
  end

  test "the live gratitude and first-person speech keep the addressed NPC's role" do
    raw =
      "[R1 · Turno de Vex] —Posadera, que sepas que esto es de agradecer —digo alzando la jarra de agua con una sonrisa—. El pan está de muerte y el cuarto gratis es mejor recompensa que la mitad del botín. Nos quedamos aquí, descansando y sin líos, que hoy ya he tenido bastante emoción con un goblin y un saquito."

    expected = String.replace_prefix(raw, "[R1 · Turno de Vex] ", "")
    assert Text.scrub(raw, "Vex", pc_names: @pcs, wait_for_human: true) == expected
    assert Text.scrub(expected, "Vex", pc_names: @pcs, wait_for_human: true) == expected
  end

  test "a recipient's immediate relative response is still foreign speech without losing the recipient" do
    for {raw, own} <- [
          {"Me acerco a la posadera, que responde: «Cerrad la puerta».",
           "Me acerco a la posadera"},
          {"Le digo buenos días a la posadera, que me contesta: «Cerrad la puerta».",
           "Le digo buenos días a la posadera"},
          {"Le pregunto al tabernero, que susurra: «Cerrad la puerta».",
           "Le pregunto al tabernero"}
        ] do
      assert Text.scrub(raw, "Vex", pc_names: @pcs) == own
      assert Text.scrub(own, "Vex", pc_names: @pcs) == own
    end
  end

  test "partial streaming keeps the recipient when the PC's own closing dash arrives" do
    for tail <- ["la posadera", "la posadera—", "la posadera—."] do
      raw = "—Muchas gracias —digo a " <> tail
      assert Chat.live_shown(raw, "Vex", @pcs) == raw
    end

    assert Chat.live_shown(@sample, "Vex", @pcs) == @sample
    refute Chat.live_shown("Alzo la jarra. La posadera: «Venid", "Vex", @pcs) =~ "Venid"
  end
end
