defmodule Dragonex.NPCObservationQuestionTest do
  use ExUnit.Case, async: true
  alias Dragonex.Text

  @question "Le pregunto a la posadera: «¿Viste tú misma marcharse al forastero o te lo contó alguien?» Espero aquí su respuesta."

  test "past observation questions preserve the player's spoken words exactly" do
    assert Text.literal_npc_speech(@question) ==
             "—¿Viste tú misma marcharse al forastero o te lo contó alguien?"

    for {question, speech} <- [
          {"Le pregunto a la tabernera: «¿Oíste al forastero preguntar por las semillas?» Espero aquí su respuesta.",
           "—¿Oíste al forastero preguntar por las semillas?"},
          {"Le pregunto al posadero: ¿Escuchaste lo que dijo en el mercado?",
           "—¿Escuchaste lo que dijo en el mercado?"},
          {"—La posadera, ¿Tú viste por dónde salió?", "—¿Tú viste por dónde salió?"},
          {"Le pregunto a la tabernera: ¿TÚ OÍSTE su nombre?", "—¿TÚ OÍSTE su nombre?"}
        ] do
      assert Text.literal_npc_speech(question) == speech
    end
  end

  test "requests, additional actions and unqualified speech retain normal resolution" do
    for question <- [
          @question <> " Después lanzo False Life sobre mí.",
          @question <> " Le pago tres monedas.",
          @question <> " Camino hasta el molino.",
          @question <> " Espero cinco minutos.",
          "Le pregunto a la tabernera: ¿Puedes acompañarme hasta el molino?",
          "Le pregunto a la tabernera: ¿Me dejas pasar gratis?",
          "Le pregunto a la tabernera: ¿Podría convencerte para que nos dejes pasar?",
          "Le pregunto a la tabernera: ¿Viste al forastero? Lyra se acerca a la barra.",
          "Le pregunto a la tabernera: ¿Viste al forastero? Lyra, ¿quieres una jarra?",
          "Lyra, ¿viste al forastero?",
          "¿Viste al forastero?"
        ] do
      assert Text.literal_npc_speech(question) == nil, question
    end
  end
end
