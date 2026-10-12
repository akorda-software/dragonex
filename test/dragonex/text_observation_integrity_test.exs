defmodule Dragonex.TextObservationIntegrityTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat

  @pcs ["Iria del Alba", "Lyra", "Vex", "Mara de la Bruma", "Nera del Camino", "Thane"]
  @samples for {actor, file} <- [
                 {"Lyra", "pc_lyra_light_hour.txt"},
                 {"Mara de la Bruma", "pc_mara_light_jar.txt"},
                 {"Nera del Camino", "pc_nera_forest_truth.txt"}
               ],
               do:
                 {actor,
                  File.read!(Path.expand("../fixtures/narration/" <> file, __DIR__))
                  |> String.trim()}

  for {actor, raw} <- @samples do
    test "the complete live observation from #{actor} stays complete" do
      actor = unquote(actor)
      raw = unquote(raw)
      assert Text.scrub(raw, actor, pc_names: @pcs, wait_for_human: true) == raw
      assert Chat.live_shown(raw, actor, @pcs, @pcs) == raw
    end
  end

  test "figurative observations do not acquire a foreign NPC speaker" do
    for raw <- [
          "La luz me dice la hora del día.",
          "El bosque me dice la verdad.",
          "La jarra nos dice la orientación del edificio.",
          "El reflejo responde a mi pregunta.",
          "La corteza no tiene: ni marcas ni arañazos."
        ] do
      assert Text.scrub(raw, "Lyra", pc_names: @pcs, wait_for_human: true) == raw
    end
  end

  test "foreign role and registered NPC dialogue is still cut while the PC keeps their own voice" do
    for raw <- [
          "Me quedo junto a la mesa. —Esperad aquí —dice el tabernero.",
          "Me quedo junto a la mesa. «Esperad aquí», dice el testigo.",
          "Me quedo junto a la mesa. dice el Sena: «Esperad aquí»."
        ] do
      clean = Text.scrub(raw, "Lyra", pc_names: @pcs, character_names: @pcs ++ ["Sena"])
      assert clean =~ "Me quedo junto a la mesa."
      refute clean =~ "dice el"
    end

    own = "—Prefiero esperar —dice Lyra."
    assert Text.scrub(own, "Lyra", pc_names: @pcs) == own
  end

  test "the seal still cannot be broken by a waiting companion but light can refract" do
    raw = "La luz se quiebra en la jarra. El viento canta."
    assert Text.scrub(raw, "Lyra", pc_names: @pcs, wait_for_human: true) == raw

    cut =
      Text.scrub("Observo el sello y quiebra el lacre. El viento canta.", "Lyra",
        pc_names: @pcs,
        wait_for_human: true
      )

    refute cut =~ "quiebra el lacre"
    assert cut =~ "El viento canta."
  end

  test "stat cleanup removes real numbers without erasing an unrelated grammatical colon" do
    raw = "El bosque tiene: robles y abedules. El enemigo queda en 3/7 pg."
    clean = Text.scrub(raw, "Lyra", pc_names: @pcs)
    assert clean =~ "El bosque tiene: robles y abedules."
    refute clean =~ "3/7"
  end
end
