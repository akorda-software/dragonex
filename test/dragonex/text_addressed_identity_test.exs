defmodule Dragonex.TextAddressedIdentityTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text

  test "an unambiguous short vocative returns its canonical human name" do
    for question <- [
          "Sylvi, ¿qué quieres observar?",
          "¿Qué prefieres, sylvi?",
          "[DM]: Sylvi: ¿lo abres?"
        ] do
      assert Text.addressed_pc(question, ["Sylvi del Roble"]) == {:named, "Sylvi del Roble"}
    end
  end

  test "a longer registered NPC or AI name cannot become the human's prefix" do
    registered = ["Lyra", "Lyra del Muelle", "Vex"]

    assert Text.addressed_pc("Lyra del Muelle, ¿qué sabes del camino?", ["Lyra"], registered) ==
             nil

    assert Text.addressed_pc("Vex, ¿qué sabes del camino?", ["Lyra"], registered) == nil

    assert Text.addressed_pc("Lyra, ¿qué quieres observar?", ["Lyra"], registered) ==
             {:named, "Lyra"}
  end

  test "an ambiguous short name does not force a recipient; full names retain ownership" do
    registered = ["Mara del Río", "Mara del Bosque"]
    assert Text.addressed_pc("Mara, ¿qué prefieres?", ["Mara del Río"], registered) == nil

    assert Text.addressed_pc("Mara del Río, ¿qué prefieres?", ["Mara del Río"], registered) ==
             {:named, "Mara del Río"}

    assert Text.addressed_pc("Mara del Bosque, ¿qué prefieres?", ["Mara del Río"], registered) ==
             nil
  end

  test "Unicode and punctuation in canonical names remain literal" do
    assert Text.addressed_pc("Íñigo, ¿qué quieres mirar?", ["Íñigo de Akorda"]) ==
             {:named, "Íñigo de Akorda"}

    assert Text.addressed_pc("Ana (II), ¿lo abres?", ["Ana (II)"]) == {:named, "Ana (II)"}
    assert Text.addressed_pc("Sylvia, ¿lo abres?", ["Sylvi del Roble"]) == :question
  end

  test "several named humans keep the question generic instead of selecting by roster order" do
    for names <- [["Thane", "Lyra"], ["Lyra", "Thane"]] do
      assert Text.addressed_pc("Thane y Lyra, ¿qué preferís observar?", names) == :question
    end
  end

  test "ordinary questions and prose retain the previous contract" do
    assert Text.addressed_pc("¿Lo abres?", ["Thane"]) == :question
    assert Text.addressed_pc("Ábrelo tú, si quieres.", ["Thane"]) == :question
    assert Text.addressed_pc("Sylvi está junto a la ventana.", ["Sylvi del Roble"]) == nil
    assert Text.addressed_pc("Sylvi, pasa al fondo.", ["Sylvi del Roble"]) == nil
    assert Text.addressed_pc(nil, ["Thane"]) == nil
  end
end
