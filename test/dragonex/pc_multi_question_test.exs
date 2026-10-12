defmodule Dragonex.PCMultiQuestionTest do
  use ExUnit.Case, async: true
  alias Dragonex.Text

  @names ["Lyra", "Vex"]
  @body "¿qué cambia la última aclaración del zagal para nuestra pista del hilo? ¿Qué proponéis hacer ahora y por qué?"
  @double "Lyra, Vex, #{@body} Espero vuestras respuestas antes de decidir."

  test "two or three consecutive informative questions keep the human words and passive wait" do
    for {text, speech} <- [
          {@double, "—Lyra, Vex, #{@body}"},
          {"—Vex, ¿Qué viste? ¿Qué parte dudas? Espero tu respuesta.",
           "—Vex, ¿Qué viste? ¿Qué parte dudas?"},
          {"Vex y Lyra, ¿De qué dirección venía?\n¿Cuál es vuestra hipótesis?\n¿Por qué la preferís? Espero aquí las respuestas.",
           "—Vex y Lyra, ¿De qué dirección venía?\n¿Cuál es vuestra hipótesis?\n¿Por qué la preferís?"}
        ] do
      assert Text.literal_pc_speech(text, @names) == speech
      assert Text.pc_question_only?(text, @names)
    end
  end

  test "every question, the shared vocative and the entire tail must qualify" do
    for text <- [
          "Lyra, Vex, ¿Qué viste? ¿Puedes abrir la puerta?",
          "Lyra, Vex, ¿Qué viste? ¿Podrías lanzar False Life?",
          "Lyra, Vex, ¿Qué viste? ¿Dónde ocurrió? ¿Puedes atacar al guardia?",
          "Lyra, Vex, ¿Qué viste? ¿Dónde ocurrió? ¿Quién estaba? ¿Por qué dudas?",
          "Lyra, Vex, ¿Qué viste? Lanzo False Life. ¿Por qué dudas?",
          "Lyra, Vex, ¿Qué viste? Lyra, ¿Por qué dudas?",
          "Lyra, Vex, ¿Qué viste? —¿Por qué dudas?",
          "Lyra, Vex, ¿Qué viste? ¿¿Por qué dudas?",
          "Lyra, Vex, ¿Qué viste? ¿Por qué dudas??",
          "Lyra, Vex, ¿Qué viste? ¿Por qué dudas",
          @double <> " Después lanzo False Life sobre mí.",
          @double <> " Camino cuesta arriba.",
          "Lyra, Vex, #{@body} Espero cinco minutos.",
          "Lyra, Vex, #{@body} Le pago tres monedas.",
          "«#{@double}» es lo que dice la nota.",
          "Vex y vex, ¿Qué viste? ¿Por qué dudas?",
          "Vexx, ¿Qué viste? ¿Por qué dudas?",
          nil
        ] do
      assert Text.literal_pc_speech(text, @names) == nil, inspect(text)
      refute Text.pc_question_only?(text, @names), inspect(text)
    end

    ambiguous = "Mara, ¿Qué viste? ¿Por qué dudas?"
    assert Text.literal_pc_speech(ambiguous, ["Mara del Río", "Mara del Bosque"]) == nil
    refute Text.pc_question_only?(ambiguous, ["Mara del Río", "Mara del Bosque"])

    assert Text.literal_pc_speech("Lyra del Muelle, #{@body}", ["Lyra"], [
             "Lyra",
             "Lyra del Muelle"
           ]) == nil
  end

  test "a world vocative or clause inside any question keeps DM even when speech is literal" do
    for body <- [
          "¿Qué viste? ¿Qué viste, Maribel?",
          "¿Qué viste? ¿Qué recuerdas; y qué dice la posadera?",
          "¿Qué viste? ¿Qué recuerdas: la voz o la tela?",
          "¿Qué viste, Maribel? ¿Por qué dudas?"
        ] do
      text = "Lyra, Vex, #{body} Espero vuestras respuestas."
      assert Text.literal_pc_speech(text, @names) == "—Lyra, Vex, #{body}"
      refute Text.pc_question_only?(text, @names)
    end
  end
end
