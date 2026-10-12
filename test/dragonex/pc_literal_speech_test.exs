defmodule Dragonex.PCLiteralSpeechTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Conversation, Text, World}
  alias Dragonex.Game.Conversations

  @question "Lyra, Vex, ¿qué recordáis de cómo terminó el combate en el granero? Espero vuestras respuestas antes de decidir qué hacer."
  @speech "—Lyra, Vex, ¿qué recordáis de cómo terminó el combate en el granero?"

  test "prepositional information is literal and qualifies as a simple PC question" do
    for question <- [
          "¿De qué dirección dijo el zagal que venía?",
          "¿Por qué dudas de su versión?",
          "¿Con quién habló el forastero?",
          "¿Hacia dónde seguirías la pista?",
          "¿Desde cuándo se interesa por las semillas?",
          "¿Para qué querría el saquito?"
        ] do
      text = "Lyra, Vex, #{question} Espero vuestras respuestas."
      assert Text.literal_pc_speech(text, ["Lyra", "Vex"]) == "—Lyra, Vex, " <> question
      assert Text.pc_question_only?(text, ["Lyra", "Vex"])
    end
  end

  test "prepositional PC speech still excludes extra actions, uncertain recipients and requests" do
    text = "Vex, ¿De qué dirección venía el forastero?"

    for suffix <- [
          " Lanzo False Life sobre mí.",
          " Le pago tres monedas.",
          " Camino hacia el norte.",
          " Espero cinco minutos.",
          " Lyra se acerca.",
          " Lyra, ¿qué viste tú?"
        ] do
      assert Text.literal_pc_speech(text <> suffix, ["Lyra", "Vex"]) == nil
      refute Text.pc_question_only?(text <> suffix, ["Lyra", "Vex"])
    end

    assert Text.literal_pc_speech("Mara, ¿De qué dirección venía?", [
             "Mara del Río",
             "Mara del Bosque"
           ]) == nil

    assert Text.literal_pc_speech("Vex, ¿Por favor puedes abrir la puerta?", ["Vex"]) == nil
    refute Text.pc_question_only?("Vex, ¿De qué dirección venía, Lyra?", ["Vex"])
  end

  test "memory and observation questions preserve the live words and literal vocative order" do
    assert Text.literal_pc_speech(@question, ["Lyra", "Vex"]) == @speech

    for {input, expected} <- [
          {"Vex, Lyra, ¿recordáis si el disparo fue un crítico? Espero vuestras respuestas antes de decidir.",
           "—Vex, Lyra, ¿recordáis si el disparo fue un crítico?"},
          {"—Vex, ¿Qué viste en el granero? Espero tu respuesta.",
           "—Vex, ¿Qué viste en el granero?"},
          {"Lyra y Vex, ¿Vosotros oísteis al forastero? Espero aquí las respuestas.",
           "—Lyra y Vex, ¿Vosotros oísteis al forastero?"},
          {"Íñigo y Ana (II), ¿qué sabéis del mercado?",
           "—Íñigo y Ana (II), ¿qué sabéis del mercado?"}
        ] do
      assert Text.literal_pc_speech(input, ["Lyra", "Vex", "Íñigo de Akorda", "Ana (II)"]) ==
               expected
    end
  end

  test "simple information and opinion questions preserve the player's actual words" do
    for input <- [
          "Lyra, Vex, ¿qué os parece ir al cruce del molino a hablar con el zagal?",
          "Vex y Lyra, ¿qué preferís observar aquí?",
          "Lyra, ¿cuál de estas pistas te interesa más?",
          "Vex, ¿dónde está el cruce del molino?",
          "Lyra, ¿cómo te gustaría investigar las semillas?"
        ] do
      assert Text.literal_pc_speech(input, ["Lyra", "Vex"]) == "—" <> input
    end
  end

  test "an opinion still needs the exact complete registered manual request" do
    text = "Lyra, Vex, ¿qué os parece ir al cruce del molino? Espero vuestras respuestas."

    world =
      World.new(
        characters: %{
          "Thane" => Archetypes.fighter(),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue()
        }
      )

    {:ok, asked} = Conversation.request("Thane", ["Lyra", "Vex"], text).(world)
    state = %Dragonex.Game{participants: %{"Thane" => %{kind: :human}}, pc_agents: %{}}

    assert Conversations.literal_pc_speech(state, "Thane", text, asked) ==
             "—Lyra, Vex, ¿qué os parece ir al cruce del molino?"

    for changed <- [
          %{state | pending_mini: true},
          %{state | last_was_mini: true},
          %{state | tm_reeval: true},
          %{state | interrupted: "Vex"},
          %{state | pc_agents: %{"Thane" => self()}},
          %{state | participants: %{"Thane" => %{kind: :agent}}}
        ] do
      assert Conversations.literal_pc_speech(changed, "Thane", text, asked) == nil
    end

    assert Conversations.literal_pc_speech(state, "Thane", text, world) == nil

    assert Conversations.literal_pc_speech(state, "Thane", text <> " Camino al molino.", asked) ==
             nil

    assert Conversations.literal_pc_speech(state, "Thane", text, %{asked | phase: :combat}) == nil

    assert Conversations.literal_pc_speech(
             state,
             "Thane",
             text,
             put_in(asked.conversation["pending"], ["Vex"])
           ) == nil
  end

  test "requests, extra actions, timed waits and ambiguous identities retain resolution" do
    for input <- [
          @question <> " Lanzo False Life sobre mí.",
          @question <> " Le pago tres monedas.",
          "Vex, ¿qué viste? Camino hacia la puerta.",
          "Vex, ¿qué viste? Espero cinco minutos.",
          "Vex, ¿qué viste? Lyra se acerca a la barra.",
          "Vex, ¿qué viste? Lyra, ¿qué oíste tú?",
          "Vex, ¿puedes pedir agua a la posadera?",
          "Lyra, ¿podrías lanzar un hechizo?",
          "¿Qué recuerdas, Vex?",
          "Le pregunto a la posadera: ¿Qué viste?",
          "«Vex, ¿qué viste?» es lo que dice la nota.",
          "Vex y vex, ¿qué recuerdas?",
          "Vexx, ¿qué recuerdas?",
          "Vex, ¿qué recuerdas",
          nil
        ] do
      assert Text.literal_pc_speech(input, ["Lyra", "Vex"]) == nil, inspect(input)
    end

    assert Text.literal_pc_speech("Mara, ¿qué viste?", ["Mara del Río", "Mara del Bosque"]) == nil

    assert Text.literal_pc_speech("Lyra del Muelle, ¿qué viste?", ["Lyra"], [
             "Lyra",
             "Lyra del Muelle"
           ]) == nil
  end

  test "only the complete matching request of a manual actor can publish locally" do
    world =
      World.new(
        characters: %{
          "Thane" => Archetypes.fighter(),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue()
        }
      )

    {:ok, asked} = Conversation.request("Thane", ["Lyra", "Vex"], @question).(world)
    state = %Dragonex.Game{participants: %{"Thane" => %{kind: :human}}, pc_agents: %{}}
    assert Conversations.literal_pc_speech(state, "Thane", @question, asked) == @speech
    assert Conversations.literal_pc_speech(state, "Thane", @question, world) == nil

    assert Conversations.literal_pc_speech(state, "Thane", @question <> " Más texto.", asked) ==
             nil

    for changed <- [
          %{state | pending_mini: true},
          %{state | last_was_mini: true},
          %{state | tm_reeval: true},
          %{state | interrupted: "Vex"},
          %{state | pc_agents: %{"Thane" => self()}},
          %{state | participants: %{"Thane" => %{kind: :agent}}}
        ] do
      assert Conversations.literal_pc_speech(changed, "Thane", @question, asked) == nil
    end

    assert Conversations.literal_pc_speech(state, "Thane", @question, %{asked | phase: :combat}) ==
             nil

    assert Conversations.literal_pc_speech(state, "Lyra", @question, asked) == nil

    assert Conversations.literal_pc_speech(
             state,
             "Thane",
             @question,
             put_in(asked.conversation["pending"], ["Vex"])
           ) == nil

    assert Conversations.literal_pc_speech(
             state,
             "Thane",
             @question,
             put_in(asked.conversation["recipients"], ["Vex", "Lyra"])
           ) == nil
  end
end
