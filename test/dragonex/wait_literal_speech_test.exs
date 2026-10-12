defmodule Dragonex.WaitLiteralSpeechTest do
  use ExUnit.Case, async: true
  alias Dragonex.WaitDeclaration

  test "a passive timed wait preserves the player's original words" do
    for text <- [
          "Espero cinco minutos junto a la barra.",
          "Yo aguardo durante quince minutos aquí.",
          "Espero aquí durante treinta y cinco segundos.",
          "Espero veintidós minutos sin moverme.",
          "Me quedo junto a la barra durante dos horas.",
          "Permanezco aquí durante una hora.",
          "Espero un minuto."
        ] do
      assert WaitDeclaration.literal_speech("  " <> text <> "  ") == text
    end
  end

  test "a duration alone does not bypass resolution of other declared actions" do
    for text <- [
          "Espero cinco minutos junto a la barra. Luego lanzo False Life sobre mí.",
          "Espero cinco minutos mientras lanzo Proyectil mágico.",
          "Espero cinco minutos y ataco al goblin.",
          "Espero veinte minutos junto a la barra mientras termino mi guiso. Luego le cuento a Maribel lo del goblin.",
          "Me quedo y lanzo un hechizo durante cinco minutos.",
          "Espero cinco minutos en el bosque y camino al pueblo.",
          "Espero cinco minutos si vuelve Maribel."
        ] do
      assert WaitDeclaration.literal_speech(text) == nil, text
    end
  end

  test "questions, quotes and invalid intervals retain the normal model path" do
    for text <- [
          nil,
          5,
          "",
          "¿Espero cinco minutos?",
          "No espero cinco minutos.",
          "Maribel dice: «Espero cinco minutos».",
          "Espero 0 minutos.",
          "Espero 99999 horas."
        ] do
      assert WaitDeclaration.literal_speech(text) == nil
    end
  end
end
