defmodule Dragonex.WaitDeclarationTest do
  use ExUnit.Case, async: true
  alias Dragonex.WaitDeclaration

  @meal "Espero veinte minutos junto a la barra mientras termino mi guiso. Luego le cuento a Maribel cómo recuperamos el saquito del goblin en el granero y espero aquí su reacción."

  test "the real meal wait has a duration calculated from the original declaration" do
    assert WaitDeclaration.seconds(@meal) == 1200
  end

  test "affirmative waits accept Spanish counts and explicit units" do
    for {text, seconds} <- [
          {"Espero 20 minutos junto a la barra.", 1200},
          {"Yo aguardo durante quince minutos aquí.", 900},
          {"Espero aquí durante treinta y cinco segundos.", 35},
          {"Espero veintidós minutos sin moverme.", 1320},
          {"Me quedo junto a la barra durante dos horas.", 7200},
          {"Permanezco aquí durante una hora.", 3600},
          {"Espero un minuto mientras escucho.", 60}
        ] do
      assert WaitDeclaration.seconds(text) == seconds, text
    end
  end

  test "questions, proposals, reports, travel and rests do not become completed waits" do
    for text <- [
          "¿Espero veinte minutos?",
          "Podríamos esperar veinte minutos.",
          "Quiero saber si conviene esperar veinte minutos.",
          "Maribel dice: «Espero veinte minutos».",
          "Esperé veinte minutos; no ha transcurrido otro intervalo.",
          "Confirmo que esperé veinte minutos junto a la barra.",
          "No espero veinte minutos.",
          "Espero veinte minutos si Maribel vuelve.",
          "Espero veinte minutos hasta que llegue Maribel.",
          "Espero veinte minutos y luego otros diez minutos.",
          "Espero veinte minutos; después hago un descanso corto.",
          "Descanso una hora junto a la barra.",
          "Camino durante quince minutos hasta el cruce.",
          "La ruta tarda veinte minutos.",
          "Espero aquí su respuesta."
        ] do
      assert WaitDeclaration.seconds(text) == nil, text
    end
  end

  test "malformed and unbounded durations keep their existing resolution path" do
    for text <- [nil, 20, "", "Espero 0 minutos.", "Espero -2 minutos.", "Espero 99999 horas."] do
      assert WaitDeclaration.seconds(text) == nil
    end
  end
end
