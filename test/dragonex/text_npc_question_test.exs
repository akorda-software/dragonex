defmodule Dragonex.TextNPCQuestionTest do
  use ExUnit.Case, async: true
  alias Dragonex.Text

  test "literal NPC role questions allow a spatial prefix, quotes and listening companions" do
    assert Text.explicit_npc_question(
             "Desde la ventana le pregunto a la posadera: «Antes de salir, ¿qué camino lleva al pueblo y hay algo de lo que deba tener cuidado?» Lyra y Vex pueden escuchar; yo espero aquí su respuesta."
           ) == "la posadera"

    assert Text.explicit_npc_question(
             "Desde la ventana le pregunto a la posadera: «¿Qué camino lleva al pueblo?» Lyra y Vex pueden escuchar."
           ) == "la posadera"

    assert Text.explicit_npc_question("Pregunto al posadero: ¿Hay agua?") == "el posadero"
    assert Text.explicit_npc_question("—La tabernera, ¿qué prepara hoy?") == "la tabernera"

    assert Text.explicit_npc_question("Le pregunto a la anciana, ¿conoce este lugar?") ==
             "la anciana"
  end

  test "mentions, quoted reports, plans, negation and mixed questions keep their existing route" do
    for text <- [
          "Lyra, ¿puedes preguntar a la posadera por el camino?",
          "Vex y Lyra, ¿qué os parece preguntar al posadero?",
          "Me pregunto si la posadera conoce el camino.",
          "No le pregunto a la posadera: ¿hay agua?",
          "Después le preguntaré a la posadera: ¿hay agua?",
          "Si puedo, le pregunto a la posadera: ¿hay agua?",
          "«Le pregunto a la posadera: ¿hay agua?» dice Vex.",
          "Recuerdo que le pregunto a la posadera: ¿hay agua?",
          "Le pregunto a la posadera por el camino.",
          "Le pregunto a la posadera: ¿hay agua? Lyra, ¿quieres una jarra?",
          "Le pregunto a Lyra: ¿hay agua?",
          "Le pregunto a la posadera: Lyra, ¿quieres agua?",
          "La posadera espera cerca de Lyra.",
          nil
        ],
        do: assert(Text.explicit_npc_question(text) == nil, inspect(text))
  end

  test "village occupations and a short qualifier identify the actual NPC recipient" do
    for {text, recipient} <- [
          {"Le pregunto al zagal: «¿Viste al forastero?» Espero aquí su respuesta.", "el zagal"},
          {"Le pregunto al zagal de las cabras: «¿Qué te dijo?»", "el zagal de las cabras"},
          {"Pregunto al molinero del pueblo: ¿Cuándo pasó por aquí?", "el molinero del pueblo"},
          {"—La herrera, ¿cuánto cuesta reparar esto?", "la herrera"},
          {"Le pregunto a la pastora: ¿Dónde está el rebaño?", "la pastora"},
          {"Le pregunto al mercader: ¿Qué vendes?", "el mercader"},
          {"Le pregunto al guardia: ¿Hay paso hacia el norte?", "el guardia"},
          {"Le pregunto a la curandera: ¿Qué sabes de las semillas?", "la curandera"}
        ] do
      assert Text.explicit_npc_question(text) == recipient
    end

    for text <- [
          "Le pregunto al zagalote: ¿Qué sabes?",
          "Le pregunto al zagal del molino y entro en la casa: ¿Qué sabes?",
          "Le pregunto al zagal del camino del norte: ¿Qué sabes?",
          "Después preguntaré al zagal: ¿Qué sabes?"
        ] do
      assert Text.explicit_npc_question(text) == nil
    end
  end

  test "registered PC names take precedence over role labels, with whole word boundaries" do
    for {text, names} <- [
          {"Le pregunto al zagal: ¿Qué sabes?", ["El Zagal"]},
          {"Le pregunto al zagal: ¿Qué sabes?", ["Zagal de Akorda"]},
          {"Le pregunto a la enana: ¿Qué sabes?", ["La Enana"]},
          {"Le pregunto al capitán: ¿Qué sabes?", ["Capita\u0301n de Akorda"]},
          {"Le pregunto al zagal de Vex: ¿Qué sabes?", ["Vex"]}
        ] do
      assert Text.explicit_npc_question(text, pc_names: names) == nil
    end

    assert Text.explicit_npc_question("Le pregunto al zagal: ¿Qué sabes?",
             pc_names: ["Zagalote", "El Caballero", "Lyra", "Vex"]
           ) == "el zagal"

    assert Text.explicit_npc_question(nil, pc_names: ["Vex"]) == nil
  end
end
