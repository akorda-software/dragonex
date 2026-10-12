defmodule Dragonex.NPCNamedSpeechTest do
  use ExUnit.Case, async: true
  alias Dragonex.Text

  @pcs ["Thane", "Lyra", "Vex"]
  @question "Le pregunto a Ada: «¿Cuándo viste el farol por última vez? ¿Desde dónde lo viste? ¿Sabes si sigue allí?» Espero aquí su respuesta."
  @speech "—¿Cuándo viste el farol por última vez? ¿Desde dónde lo viste? ¿Sabes si sigue allí?"

  test "a single proper NPC name preserves the real three-question declaration" do
    assert Text.explicit_npc_question(@question, pc_names: @pcs) == "ada"
    assert Text.literal_npc_speech(@question, pc_names: @pcs) == @speech

    for name <- ["Ada", "ADA", "Ágata", "Ágata", "Jean-Luc", "D’Arcy"] do
      text = "Le pregunto a #{name}: «¿Qué viste?» Espero aquí su respuesta."
      assert Text.literal_npc_speech(text, pc_names: @pcs) == "—¿Qué viste?"
      assert Text.explicit_npc_question(text, pc_names: @pcs) == String.downcase(name)
    end

    assert Text.literal_npc_speech("—Ada, ¿dónde lo viste?", pc_names: @pcs) ==
             "—¿dónde lo viste?"

    assert Text.literal_npc_speech("Le pregunto a Ada: ¿Hay paso?", pc_names: @pcs) ==
             "—¿Hay paso?"

    clarification = "Le pregunto a Ada: «Cuando dices que lo viste ayer, ¿desde dónde lo viste?»"

    assert Text.literal_npc_clarification(clarification, pc_names: @pcs) ==
             {"ada", "—Cuando dices que lo viste ayer, ¿desde dónde lo viste?"}
  end

  test "a named NPC requires roster context and cannot capture PC identities or first names" do
    assert Text.explicit_npc_question(@question) == nil
    assert Text.literal_npc_speech(@question, pc_names: []) == nil

    for {name, pcs} <- [
          {"Ada", ["Ada"]},
          {"Ada", ["Ada de Roble"]},
          {"ADA", ["Ada de Roble", "Ada del Vado"]},
          {"Ágata", ["Ágata de Roble"]},
          {"Lyra", @pcs},
          {"Thane", @pcs}
        ] do
      text = "Le pregunto a #{name}: «¿Qué viste?»"
      assert Text.explicit_npc_question(text, pc_names: pcs) == nil
      assert Text.literal_npc_speech(text, pc_names: pcs) == nil
    end

    assert Text.explicit_npc_question(@question, pc_names: ["Adam de Roble"]) == "ada"
  end

  test "proper names keep quote, information, passive wait and bounded recipient guards" do
    for text <- [
          @question <> " Camino al cobertizo.",
          @question <> " Lanzo False Life sobre mí.",
          @question <> " Espero cinco minutos.",
          String.replace(@question, "¿Sabes si sigue allí?", "¿Puedes traer el farol?"),
          String.replace(@question, "¿Sabes si sigue allí?", "Lyra, ¿qué viste?"),
          String.replace(@question, "»", " ¿Quién lo movió?»"),
          String.replace(@question, "»", "”"),
          String.replace(@question, "a Ada:", "a ada:"),
          String.replace(@question, "a Ada:", "a Ada de Roble:"),
          String.replace(@question, "a Ada:", "a Ada y Vex:"),
          String.replace(@question, "a Ada:", "a Ada y entro:"),
          "No le pregunto a Ada: «¿Qué viste?»",
          "Después preguntaré a Ada: «¿Qué viste?»",
          "Le pregunto a Li: «¿Qué viste?»",
          "Le pregunto a Ada: «¿Qué viste? Camino al cobertizo. ¿Cuándo fue?»"
        ] do
      assert Text.literal_npc_speech(text, pc_names: @pcs) == nil, inspect(text)
    end
  end
end
