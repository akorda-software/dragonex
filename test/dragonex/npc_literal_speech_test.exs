defmodule Dragonex.NPCLiteralSpeechTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Conversation, Text, World}
  alias Dragonex.Game.Conversations

  @question "Le pregunto a la tabernera: «¿Qué plato sirves hoy y cuánto cuesta?» Espero junto a la barra su respuesta antes de pedir."
  @clarification "Le pregunto al zagal de las cabras: «Cuando dijiste que lo viste de lejos, ¿te referías al forastero, a su abrigo o al hilo? ¿Llegaste a ver de cerca la lana de su abrigo?» Espero aquí su respuesta."
  @clarification_speech "—Cuando dijiste que lo viste de lejos, ¿te referías al forastero, a su abrigo o al hilo? ¿Llegaste a ver de cerca la lana de su abrigo?"

  test "a quoted clarification keeps its reported preamble and both questions to the same NPC" do
    assert Text.explicit_npc_question(@clarification, pc_names: ["Thane", "Lyra", "Vex"]) ==
             "el zagal de las cabras"

    assert Text.literal_npc_speech(@clarification, pc_names: ["Thane", "Lyra", "Vex"]) ==
             @clarification_speech

    for {open, close} <- [{"«", "»"}, {"“", "”"}, {"\"", "\""}] do
      question =
        "Le pregunto al zagal: #{open}¿Qué viste? ¿Dónde estabas? ¿Cuándo ocurrió?#{close}"

      assert Text.explicit_npc_question(question) == "el zagal"
      assert Text.literal_npc_speech(question) == "—¿Qué viste? ¿Dónde estabas? ¿Cuándo ocurrió?"
    end
  end

  test "compound quoted speech cannot swallow outside actions, requests, other recipients or malformed questions" do
    for text <- [
          @clarification <> " Lanzo False Life sobre mí.",
          @clarification <> " Camino hacia el norte.",
          @clarification <> " Espero quince minutos.",
          @clarification <> " Vex recoge el botón.",
          String.replace(@clarification, "»", "”"),
          String.replace(@clarification, "¿Llegaste", "Lyra, ¿Llegaste"),
          String.replace(
            @clarification,
            "¿Llegaste a ver de cerca la lana de su abrigo?",
            "¿Puedes acompañarme al norte?"
          ),
          String.replace(
            @clarification,
            "Cuando dijiste que lo viste de lejos,",
            "Cuando termine, entro en el molino,"
          ),
          "Le pregunto al zagal: «¿Qué viste? ¿Dónde? ¿Cuándo? ¿Quién?»",
          "Le pregunto al zagal: «¿Qué viste? ¿¿Dónde estabas?»",
          "Le pregunto al zagal: «¿Qué viste? Dónde estabas?»",
          "Le pregunto al zagal: «¿Qué viste?», y pregunto a la posadera: «¿Dónde estabas?»",
          "No le pregunto al zagal: «¿Qué viste? ¿Dónde estabas?»",
          "Después preguntaré al zagal: «¿Qué viste? ¿Dónde estabas?»"
        ] do
      assert Text.explicit_npc_question(text, pc_names: ["Thane", "Lyra", "Vex"]) == nil,
             inspect(text)

      assert Text.literal_npc_speech(text, pc_names: ["Thane", "Lyra", "Vex"]) == nil,
             inspect(text)
    end

    assert Text.explicit_npc_question(@clarification, pc_names: ["El Zagal"]) == nil
    assert Text.literal_npc_speech(@clarification, pc_names: ["El Zagal"]) == nil
  end

  test "prepositional information questions preserve the exact spoken words" do
    for question <- [
          "¿De qué dirección venía el forastero antes de tomar el camino del norte?",
          "¿Por qué recuerdas el abrigo oscuro?",
          "¿Con quién hablaba junto al molino?",
          "¿A quién preguntó por la posada?",
          "¿Hacia dónde señaló después?",
          "¿Desde cuándo falta el saquito?",
          "¿En cuál de esas casas lo viste?",
          "¿Entre quiénes repartieron las semillas?",
          "¿Para qué quería el saquito?",
          "¿Por cuánto vendían el grano?"
        ] do
      text = "Le pregunto al zagal de las cabras: «#{question}» Espero aquí su respuesta."
      assert Text.literal_npc_speech(text, pc_names: ["Thane", "Lyra", "Vex"]) == "—" <> question
    end
  end

  test "prepositional questions keep action, duration, request and PC-collision guards" do
    text = "Le pregunto al zagal: «¿De qué dirección venía el forastero?»"

    for suffix <- [
          " Lanzo False Life sobre mí.",
          " Le pago tres monedas.",
          " Camino al molino.",
          " Espero quince minutos.",
          " Vex recoge el botón.",
          " ¿Y qué llevaba?"
        ] do
      assert Text.literal_npc_speech(text <> suffix) == nil
    end

    assert Text.literal_npc_speech(text, pc_names: ["El Zagal"]) == nil
    assert Text.literal_npc_speech("Le pregunto al zagal: ¿Por favor me dejas pasar?") == nil
    assert Text.literal_npc_speech("Le pregunto al zagal: ¿Conmigo vendrías al norte?") == nil

    assert Text.literal_npc_speech(
             "Le pregunto al zagal: ¿De qué dirección venía? Yo recojo el botón."
           ) == nil
  end

  test "spoken words from the real NPC questions need no paraphrase" do
    assert Text.literal_npc_speech(@question) == "—¿Qué plato sirves hoy y cuánto cuesta?"

    assert Text.literal_npc_speech(
             "Le pregunto a la tabernera: «¿Tú eres Maribel y cómo supiste lo del saquito?» Me quedo ante la puerta y espero su respuesta."
           ) ==
             "—¿Tú eres Maribel y cómo supiste lo del saquito?"

    assert Text.literal_npc_speech(
             "Desde la ventana le pregunto a la posadera: «Antes de salir, ¿qué camino lleva al pueblo?» Lyra y Vex pueden escuchar; yo espero aquí su respuesta.",
             pc_names: ["Lyra", "Vex"]
           ) ==
             "—¿qué camino lleva al pueblo?"

    assert Text.literal_npc_speech("—La tabernera, ¿qué prepara hoy?") == "—¿qué prepara hoy?"
  end

  test "additional actions and uncertain prefixes retain model resolution" do
    for text <- [
          @question <> " Lanzo False Life sobre mí.",
          "Le pregunto a la tabernera: ¿Hay agua? Tiro Percepción.",
          "Le pregunto a la tabernera: ¿Hay agua? Entro en la taberna.",
          "Le pregunto a la tabernera: ¿Hay agua? Le pago tres monedas.",
          "Le pregunto a la tabernera: ¿Nos dejas pasar gratis?",
          "Le pregunto a la tabernera: ¿Podría convencerte para que nos dejes pasar?",
          "Desde el patio ataco a Vex y le pregunto a la tabernera: ¿Hay agua?",
          "Le pregunto a la tabernera: ¿Hay agua? Lyra se acerca a la barra.",
          "Le pregunto a la tabernera: ¿Hay agua? Lyra, ¿quieres una jarra?",
          "Lyra, ¿hay agua?",
          "¿Hay agua?",
          nil
        ] do
      assert Text.literal_npc_speech(text) == nil, inspect(text)
    end
  end

  test "matching registered manual questions alone qualify for local speech" do
    world = World.new(scene: "La taberna.", characters: %{"Thane" => Archetypes.fighter()})
    {:ok, asked} = Conversation.request_world("Thane", "la tabernera", @question).(world)
    state = %Dragonex.Game{participants: %{"Thane" => %{kind: :human}}, pc_agents: %{}}
    assert Conversations.literal_npc_speech(state, "Thane", @question, asked) != nil
    assert Conversations.literal_npc_speech(state, "Thane", @question, world) == nil

    assert Conversations.literal_npc_speech(state, "Thane", @question <> " Más texto.", asked) ==
             nil

    for changed <- [
          %{state | pending_mini: true},
          %{state | tm_reeval: true},
          %{state | interrupted: "Vex"},
          %{state | pc_agents: %{"Thane" => self()}}
        ] do
      assert Conversations.literal_npc_speech(changed, "Thane", @question, asked) == nil
    end

    assert Conversations.literal_npc_speech(state, "Thane", @question, %{asked | phase: :combat}) ==
             nil
  end

  test "goatherd and qualified occupations keep exact speech but added actions still resolve" do
    question =
      "Le pregunto al zagal de las cabras: «¿Viste al forastero tomar el camino del norte y qué te dijo sobre las semillas?» Espero aquí su respuesta."

    assert Text.literal_npc_speech(question, pc_names: ["Thane", "Lyra", "Vex"]) ==
             "—¿Viste al forastero tomar el camino del norte y qué te dijo sobre las semillas?"

    assert Text.literal_npc_speech("—El molinero del pueblo, ¿qué viste?") == "—¿qué viste?"
    assert Text.literal_npc_speech(question, pc_names: ["El Zagal"]) == nil

    for suffix <- [
          " Lanzo False Life sobre mí.",
          " Pago tres monedas.",
          " Camino hacia el norte.",
          " Espero quince minutos.",
          " Vex recoge las semillas."
        ] do
      assert Text.literal_npc_speech(question <> suffix) == nil
    end
  end
end
