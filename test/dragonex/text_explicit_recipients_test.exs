defmodule Dragonex.TextExplicitRecipientsTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text

  test "the live jar request names Vex without treating the NPC recipient as a speaker" do
    input =
      "Vex, ¿puedes acercar tu jarra vacía a la posadera y pedirle que la llene de agua? " <>
        "Nos quedamos a la sombra; no necesito otro descanso ni nuevas aventuras."

    assert Text.explicit_pc_recipients(input, ["Lyra", "Vex"], ["Lyra", "Vex", "posadera"]) ==
             ["Vex"]
  end

  test "several explicit vocatives preserve order, canonical spelling and unique short names" do
    names = ["Lyra", "Vex", "Mara de la Bruma", "Íñigo de Akorda"]

    for {input, expected} <- [
          {"Vex y Lyra, ¿qué preferís?", ["Vex", "Lyra"]},
          {"lyra, vex y mara, ¿qué observáis?", ["Lyra", "Vex", "Mara de la Bruma"]},
          {"—Lyra e Íñigo, ¿qué pensáis?", ["Lyra", "Íñigo de Akorda"]},
          {"Mara de la Bruma, ¿puedes mirar el mapa?", ["Mara de la Bruma"]}
        ] do
      assert Text.explicit_pc_recipients(input, names) == expected
    end
  end

  test "a mention, quoted request, generic question or incomplete vocative does not route" do
    for input <- [
          "¿Qué sabe Vex del camino?",
          "Miro a Vex. ¿Qué hay tras el puente?",
          "La posadera pregunta: Vex, ¿quieres agua?",
          "«Vex, ¿puedes traer agua?» es lo que dice la nota.",
          "¿Puedes traer agua, Vex?",
          "Vex, pasa la jarra.",
          "Vex, ¿puedes traer agua",
          "Vex, ¿?",
          "¿Quién quiere agua?",
          "Vex y la posadera, ¿podéis traer agua?"
        ] do
      assert Text.explicit_pc_recipients(input, ["Lyra", "Vex"]) == []
    end

    assert Text.explicit_pc_recipients(nil, ["Vex"]) == []
    assert Text.explicit_pc_recipients("Vex, ¿puedes?", nil) == []
  end

  test "full NPC names and ambiguous short names cannot select an eligible PC by prefix" do
    registered = ["Lyra", "Lyra del Muelle", "Mara del Río", "Mara del Bosque", "Vex"]
    pcs = ["Lyra", "Mara del Río", "Mara del Bosque", "Vex"]

    for input <- ["Lyra del Muelle, ¿qué sabes?", "Mara, ¿qué sabes?", "Vex y Mara, ¿qué sabéis?"] do
      assert Text.explicit_pc_recipients(input, pcs, registered) == []
    end

    assert Text.explicit_pc_recipients("Mara del Río y Vex, ¿qué sabéis?", pcs, registered) ==
             ["Mara del Río", "Vex"]

    assert Text.explicit_pc_recipients("Lyra, ¿qué sabes?", pcs, registered) == ["Lyra"]
  end

  test "punctuation in canonical names is literal and duplicate recipients do not open a request" do
    assert Text.explicit_pc_recipients("Ana (II), ¿quieres agua?", ["Ana (II)"]) == ["Ana (II)"]
    assert Text.explicit_pc_recipients("Vex y vex, ¿quieres agua?", ["Vex"]) == []
    assert Text.explicit_pc_recipients("Vexx, ¿quieres agua?", ["Vex"]) == []
    assert Text.explicit_pc_recipients("dm, ¿quieres agua?", ["dm", "Vex"]) == []
  end
end
