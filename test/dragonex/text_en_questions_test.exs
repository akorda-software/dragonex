defmodule Dragonex.TextEnQuestionsTest do
  @moduledoc """
  English counterpart of the addressing and question suites:
  `addressed_pc`, `explicit_pc_recipients`, `literal_pc_speech`,
  `pc_question_only?`, `explicit_npc_question`, `literal_npc_speech` and
  `literal_npc_clarification` with the `:en` locale.
  """
  use ExUnit.Case, async: true

  alias Dragonex.I18n
  alias Dragonex.Text

  defp en(fun), do: I18n.with_locale(:en, fun)

  describe "addressed_pc" do
    test "detects a question to a named human, a generic prompt, or nothing" do
      en(fn ->
        assert Text.addressed_pc("Thane, the seal waits. Do you open it?", ["Thane", "Lyra"]) ==
                 {:named, "Thane"}

        assert Text.addressed_pc("Do you open it?", ["Thane"]) == :question
        assert Text.addressed_pc("Open it yourself, if you want.", ["Thane"]) == :question
        assert Text.addressed_pc("The bridge sways. What do you do", ["Thane"]) == :question
        assert Text.addressed_pc("The fire crackles in the hearth.", ["Thane"]) == nil
        assert Text.addressed_pc("Thane, go to the back.", ["Thane"]) == nil
        assert Text.addressed_pc(nil, ["Thane"]) == nil
      end)
    end

    test "short vocatives resolve to the canonical name; registered names keep ownership" do
      en(fn ->
        for question <- [
              "Sylvi, what do you want to observe?",
              "What do you prefer, sylvi?",
              "[DM]: Sylvi: do you open it?"
            ] do
          assert Text.addressed_pc(question, ["Sylvi of the Oak"]) == {:named, "Sylvi of the Oak"}
        end

        registered = ["Lyra", "Lyra of the Dock", "Vex"]

        assert Text.addressed_pc(
                 "Lyra of the Dock, what do you know about the road?",
                 ["Lyra"],
                 registered
               ) ==
                 nil

        assert Text.addressed_pc("Vex, what do you know about the road?", ["Lyra"], registered) ==
                 nil

        assert Text.addressed_pc("Lyra, what do you want to observe?", ["Lyra"], registered) ==
                 {:named, "Lyra"}

        for names <- [["Thane", "Lyra"], ["Lyra", "Thane"]] do
          assert Text.addressed_pc("Thane and Lyra, what would you rather observe?", names) ==
                   :question
        end

        assert Text.addressed_pc("Sylvia, can you open it?", ["Sylvi of the Oak"]) == :question
        assert Text.addressed_pc("Sylvi is by the window.", ["Sylvi of the Oak"]) == nil
      end)
    end
  end

  describe "explicit_pc_recipients" do
    test "the jar request names Vex without treating the NPC recipient as a speaker" do
      en(fn ->
        input =
          "Vex, can you bring your empty jar to the innkeeper and ask her to fill it with water? " <>
            "We stay in the shade; I need no other rest nor new adventures."

        assert Text.explicit_pc_recipients(input, ["Lyra", "Vex"], ["Lyra", "Vex", "innkeeper"]) ==
                 ["Vex"]
      end)
    end

    test "several vocatives keep order, canonical spelling and unique short names" do
      en(fn ->
        names = ["Lyra", "Vex", "Mara of the Mist", "Íñigo of Akorda"]

        for {input, expected} <- [
              {"Vex and Lyra, what would you rather do?", ["Vex", "Lyra"]},
              {"lyra, vex and mara, what do you see?", ["Lyra", "Vex", "Mara of the Mist"]},
              {"Lyra, Vex, and Mara, what do you see?", ["Lyra", "Vex", "Mara of the Mist"]},
              {"—Lyra and Íñigo, what do you think?", ["Lyra", "Íñigo of Akorda"]},
              {"Mara of the Mist, can you look at the map?", ["Mara of the Mist"]}
            ] do
          assert Text.explicit_pc_recipients(input, names) == expected
        end
      end)
    end

    test "mentions, quoted requests, generic questions and incomplete vocatives do not route" do
      en(fn ->
        for input <- [
              "What does Vex know about the road?",
              "I look at Vex. What lies beyond the bridge?",
              "The innkeeper asks: Vex, do you want water?",
              "\"Vex, can you bring water?\" is what the note says.",
              "Can you bring water, Vex?",
              "Vex, pass the jar.",
              "Vex, can you bring water",
              "Vex, ?",
              "Vex, the door is locked. Can you open it?",
              "Who wants water?",
              "Vex and the innkeeper, can you bring water?"
            ] do
          assert Text.explicit_pc_recipients(input, ["Lyra", "Vex"]) == [], input
        end

        assert Text.explicit_pc_recipients(nil, ["Vex"]) == []
        assert Text.explicit_pc_recipients("Vex, can you?", nil) == []
      end)
    end

    test "full NPC names, ambiguous short names and duplicates cannot select a PC" do
      en(fn ->
        registered = ["Lyra", "Lyra of the Dock", "Mara of the River", "Mara of the Wood", "Vex"]
        pcs = ["Lyra", "Mara of the River", "Mara of the Wood", "Vex"]

        for input <- [
              "Lyra of the Dock, what do you know?",
              "Mara, what do you know?",
              "Vex and Mara, what do you know?"
            ] do
          assert Text.explicit_pc_recipients(input, pcs, registered) == []
        end

        assert Text.explicit_pc_recipients(
                 "Mara of the River and Vex, what do you know?",
                 pcs,
                 registered
               ) ==
                 ["Mara of the River", "Vex"]

        assert Text.explicit_pc_recipients("Lyra, what do you know?", pcs, registered) == ["Lyra"]

        assert Text.explicit_pc_recipients("Ana (II), do you want water?", ["Ana (II)"]) == [
                 "Ana (II)"
               ]

        assert Text.explicit_pc_recipients("Vex and vex, do you want water?", ["Vex"]) == []
        assert Text.explicit_pc_recipients("Vexx, do you want water?", ["Vex"]) == []
        assert Text.explicit_pc_recipients("dm, do you want water?", ["dm", "Vex"]) == []
      end)
    end
  end

  describe "literal PC speech" do
    test "a vocative plus informative questions and a passive wait is spoken verbatim" do
      en(fn ->
        text = "Lyra, what do you know about the mill? I wait for your answer."

        assert Text.literal_pc_speech(text, ["Lyra", "Vex"]) ==
                 "—Lyra, what do you know about the mill?"

        assert Text.pc_question_only?(text, ["Lyra", "Vex"])

        two =
          "Lyra and Vex, what do you know about the mill? Where does the road lead? I wait for your answers."

        assert Text.literal_pc_speech(two, ["Lyra", "Vex"]) ==
                 "—Lyra and Vex, what do you know about the mill? Where does the road lead?"

        assert Text.pc_question_only?(two, ["Lyra", "Vex"])
      end)
    end

    test "requests, actions after the question and extra clauses keep the model route" do
      en(fn ->
        assert Text.literal_pc_speech("Lyra, can you open the door? I wait.", ["Lyra"]) == nil
        refute Text.pc_question_only?("Lyra, can you open the door? I wait.", ["Lyra"])
        assert Text.literal_pc_speech("Lyra, what do you know? I open the door.", ["Lyra"]) == nil

        clause = "Lyra, what do you know, and where is the mill? I wait."

        assert Text.literal_pc_speech(clause, ["Lyra"]) ==
                 "—Lyra, what do you know, and where is the mill?"

        refute Text.pc_question_only?(clause, ["Lyra"])
        refute Text.pc_question_only?("What do you know about the mill?", ["Lyra"])
      end)
    end
  end

  describe "explicit_npc_question" do
    test "literal role questions allow a spatial prefix, quotes and listening companions" do
      en(fn ->
        assert Text.explicit_npc_question(
                 "From the window I ask the innkeeper: \"Before I leave, which road leads to the village and is there anything I should watch out for?\" Lyra and Vex can listen; I wait here for her answer."
               ) == "the innkeeper"

        assert Text.explicit_npc_question(
                 "From the window I ask the innkeeper: \"Which road leads to the village?\" Lyra and Vex can listen."
               ) == "the innkeeper"

        assert Text.explicit_npc_question("I ask the innkeeper: Is there water?") ==
                 "the innkeeper"

        assert Text.explicit_npc_question("—Barkeep, what are you cooking today?") ==
                 "the barkeep"

        assert Text.explicit_npc_question("I ask the old woman, do you know this place?") ==
                 "the old woman"
      end)
    end

    test "mentions, quoted reports, plans, negation and mixed questions keep their route" do
      en(fn ->
        for text <- [
              "Lyra, can you ask the innkeeper about the road?",
              "Vex and Lyra, what do you think about asking the innkeeper?",
              "I wonder whether the innkeeper knows the road.",
              "I don't ask the innkeeper: is there water?",
              "Later I'll ask the innkeeper: is there water?",
              "If I can, I ask the innkeeper: is there water?",
              "\"I ask the innkeeper: is there water?\" says Vex.",
              "I remember that I ask the innkeeper: is there water?",
              "I ask the innkeeper about the road.",
              "I ask the innkeeper: is there water? Lyra, do you want a jug?",
              "I ask Lyra: is there water?",
              "I ask the innkeeper: Lyra, do you want water?",
              "The innkeeper waits near Lyra.",
              nil
            ],
            do: assert(Text.explicit_npc_question(text) == nil, inspect(text))
      end)
    end

    test "village occupations and a short qualifier identify the NPC recipient" do
      en(fn ->
        for {text, recipient} <- [
              {"I ask the boy: \"Did you see the stranger?\" I wait here for his answer.",
               "the boy"},
              {"I ask the boy with the goats: \"What did he tell you?\"",
               "the boy with the goats"},
              {"I ask the miller from the village: When did he pass through here?",
               "the miller from the village"},
              {"—The blacksmith, how much to repair this?", "the blacksmith"},
              {"I ask the shepherdess: Where is the flock?", "the shepherdess"},
              {"I ask the merchant: What do you sell?", "the merchant"},
              {"I ask the guard: Is there a way north?", "the guard"},
              {"I ask the healer: What do you know about the seeds?", "the healer"}
            ] do
          assert Text.explicit_npc_question(text) == recipient
        end

        for text <- [
              "I ask the boyfriend: What do you know?",
              "I ask the boy from the mill and go into the house: What do you know?",
              "I ask the boy from the north road: What do you know?",
              "Later I'll ask the boy: What do you know?"
            ] do
          assert Text.explicit_npc_question(text) == nil
        end
      end)
    end

    test "registered PC names take precedence over role labels" do
      en(fn ->
        for {text, names} <- [
              {"I ask the boy: What do you know?", ["The Boy"]},
              {"I ask the boy: What do you know?", ["Boy of Akorda"]},
              {"I ask the dwarf: What do you know?", ["The Dwarf"]},
              {"I ask the captain: What do you know?", ["Captain of Akorda"]},
              {"I ask the boy of Vex: What do you know?", ["Vex"]}
            ] do
          assert Text.explicit_npc_question(text, pc_names: names) == nil
        end

        assert Text.explicit_npc_question("I ask the boy: What do you know?",
                 pc_names: ["Boyd", "The Knight", "Lyra", "Vex"]
               ) == "the boy"
      end)
    end

    test "a single proper name needs a PC roster" do
      en(fn ->
        text = "I ask Mira: \"What did you see at the mill?\""
        assert Text.explicit_npc_question(text) == nil
        assert Text.explicit_npc_question(text, pc_names: ["Lyra", "Vex"]) == "mira"
        assert Text.explicit_npc_question("Mira, what did you see?", pc_names: ["Lyra"]) == "mira"
      end)
    end
  end

  describe "literal NPC speech and clarification" do
    test "only the quoted or unquoted question is spoken, after passive waiting" do
      en(fn ->
        assert Text.literal_npc_speech(
                 "I ask the innkeeper: \"Which road leads to the village?\" I wait here for her answer."
               ) == "—Which road leads to the village?"

        assert Text.literal_npc_speech(
                 "From the window I ask the innkeeper: \"Which road leads to the village?\" Lyra and Vex can listen; I wait here for her answer.",
                 pc_names: ["Lyra", "Vex"]
               ) == "—Which road leads to the village?"

        assert Text.literal_npc_speech(
                 "I ask the innkeeper: Which road leads to the village? I wait for her answer."
               ) == "—Which road leads to the village?"

        assert Text.literal_npc_speech("I ask Mira: 'What's on the road?' I wait for her answer.",
                 pc_names: ["Lyra"]
               ) == "—What's on the road?"
      end)
    end

    test "extra actions or requests are not literal speech" do
      en(fn ->
        assert Text.literal_npc_speech(
                 "I ask the innkeeper: Which road leads to the village? I open the door."
               ) == nil

        assert Text.literal_npc_speech("I ask the innkeeper: Can you give me water?") == nil

        assert Text.explicit_npc_question("I ask the innkeeper: Can you give me water?") ==
                 "the innkeeper"
      end)
    end

    test "a quoted recall of earlier NPC speech is a clarification" do
      en(fn ->
        text = "I ask the innkeeper: \"When you said the mill was closed, what did you mean?\""

        assert Text.literal_npc_clarification(text) ==
                 {"the innkeeper", "—When you said the mill was closed, what did you mean?"}

        assert Text.literal_npc_clarification(
                 "I ask the innkeeper: \"Which road leads to the village?\""
               ) == nil

        assert Text.literal_npc_clarification(nil) == nil
      end)
    end
  end
end
