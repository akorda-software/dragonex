defmodule Dragonex.TextEnScrubTest do
  @moduledoc """
  English counterpart of `Dragonex.TextTest` and the engine-marker suite:
  `Text.scrub/1,2,3` with the `:en` locale.
  """
  use ExUnit.Case, async: true

  alias Dragonex.I18n
  alias Dragonex.Text
  alias Dragonex.Text.Lexicon

  defp en(fun), do: I18n.with_locale(:en, fun)

  test "the lexicon follows the per-process locale" do
    assert Lexicon.current() == Lexicon.Es
    assert en(fn -> Lexicon.current() end) == Lexicon.En
  end

  describe "self-name stripping" do
    test "strips the actor's own name opening a third-person narration" do
      en(fn ->
        assert Text.scrub("Lyra raises her hand and smiles.", "Lyra") ==
                 "Raises her hand and smiles."

        assert Text.scrub("Thane draws his sword.", "Thane") == "Draws his sword."
        assert Text.scrub("—Lyra: smiles confidently.", "Lyra") == "Smiles confidently."
        assert Text.scrub("*Lyra draws her bow.*", "Lyra") == "Draws her bow."

        assert Text.scrub("**Thane**lifts the map and folds it.", "Thane") ==
                 "Lifts the map and folds it."
      end)
    end

    test "DM narration about a PC and actor-less scrubs keep the name" do
      en(fn ->
        assert Text.scrub("Lyra falls wounded from the blow.", "dm") ==
                 "Lyra falls wounded from the blow."

        assert Text.scrub("Lyra raises her hand.") == "Lyra raises her hand."

        assert Text.scrub("I raise my hand and conjure fire.", "Lyra") ==
                 "I raise my hand and conjure fire."
      end)
    end

    test "strips leaked tags together with the self-name and a possessive" do
      en(fn ->
        assert Text.scrub("[Lyra]: Lyra casts a firebolt.", "Lyra") == "Casts a firebolt."

        assert Text.scrub("Thane's hand closes around the hilt.", "Thane") ==
                 "Closes around the hilt."
      end)
    end
  end

  describe "history scaffolding" do
    test "English turn headers and decision markers never leak" do
      en(fn ->
        out =
          Text.scrub(
            "The scroll is heavy. [R2 · Turn of Thane]: Do you open it? The seal cracks.",
            "dm"
          )

        assert out == "The scroll is heavy. Do you open it? The seal cracks."

        assert Text.scrub("The door gives way. [→ Thane decides] A dull thud.", "dm") ==
                 "The door gives way. A dull thud."

        assert Text.scrub("R2 · combat · Turn of Vex\nThe goblin snarls.", "dm") ==
                 "The goblin snarls."

        assert Text.scrub("[R3 · combat · Turn of Vex] [Vex declares]: I draw my bow.", "Vex") ==
                 "I draw my bow."
      end)
    end

    test "stray labels of either language are stripped in both locales" do
      en(fn ->
        assert Text.scrub("The fire crackles. [Turn of Lyra] The rain falls.", "dm") ==
                 "The fire crackles. The rain falls."

        assert Text.scrub("Silence. [Turno de Vex] The door opens.", "dm") ==
                 "Silence. The door opens."

        assert Text.scrub("Silence. [Vex declares] The door opens.", "dm") ==
                 "Silence. The door opens."

        assert Text.scrub("Silence. [→ Vex decide] The door opens.", "dm") ==
                 "Silence. The door opens."
      end)

      assert Text.scrub("Silencio. [Turn of Vex] La puerta se abre.", "dm") ==
               "Silencio. La puerta se abre."

      assert Text.scrub("Silencio. [→ Vex decides] La puerta se abre.", "dm") ==
               "Silencio. La puerta se abre."

      assert Text.scrub("Silencio. [Vex declara] La puerta se abre.", "dm") ==
               "Silencio. La puerta se abre."
    end

    test "mid-prose [DM]: tags and a fused roll label are stripped" do
      en(fn ->
        out = Text.scrub("The shepherd falls silent. [DM]: The shepherd stands and points.", "dm")
        refute out =~ "[DM]"
        assert out =~ "The shepherd stands"

        refute Text.scrub("Lyracheck of Intelligence fails in the air.", "Lyra") =~ "Lyracheck"
        refute Text.scrub("The air hums. Lyraattack misses.", "Lyra") =~ "Lyraattack"
      end)
    end
  end

  describe "stats" do
    test "strips HP and AC leaks in English prose" do
      en(fn ->
        out = Text.scrub("The goblin is at 3/7 hp.", "dm")
        assert out =~ "The goblin"
        refute out =~ "3/7"

        refute Text.scrub("The skeleton has 7 hp.", "dm") =~ "7 hp"
        refute Text.scrub("It has 10 HP left.", "Thane") =~ "10"
        refute Text.scrub("Its AC is 15.", "dm") =~ "AC"
        refute Text.scrub("Armor Class 13.", "dm") =~ "13"
        refute Text.scrub("She has 1 of her 7 original hit points left.", "dm") =~ "1 of"
        refute Text.scrub("He drops to 5 hit points.", "dm") =~ "5 hit points"
      end)
    end

    test "keeps lore numbers that are not stats" do
      en(fn ->
        assert Text.scrub("You find 15 gold coins.", "dm") == "You find 15 gold coins."

        assert Text.scrub("You see 3 doors to the north.", "dm") ==
                 "You see 3 doors to the north."

        assert Text.scrub("The cache is hidden.", "dm") == "The cache is hidden."
      end)
    end

    test "drops stat parentheses, dice notation and empty shells" do
      en(fn ->
        assert Text.scrub("A test devil appears (AC 12, HP 13, damage 1d4+2 with trident).", "dm") ==
                 "A test devil appears."

        refute Text.scrub("The weapon deals 1d4+2 damage.", "dm") =~ "1d4"
        assert Text.scrub("He rolled a natural d20.", "dm") =~ "d20"

        out = Text.scrub("The hound falls. **Practice Hound: 7 HP** End.", "dm")
        refute out =~ "**"
        refute out =~ "7 HP"
        assert out =~ "The hound falls"

        out = Text.scrub("Lyra is left with **1 of 6 HP**.", "dm")
        refute out =~ "HP"
        refute out =~ ~r/\b1 of\b/
      end)
    end

    test "drops an English combat recap block" do
      en(fn ->
        raw =
          "The goblin staggers.\n**Combat Status:**\n- Goblin: 3/7 hp\n- Thane: AC 16\nThe fog thickens."

        out = Text.scrub(raw, "dm")
        refute out =~ "Combat Status"
        refute out =~ "Goblin:"
        assert out =~ "The goblin staggers."
        assert out =~ "The fog thickens."
      end)
    end
  end

  describe "engine leaks" do
    test "drops narrated tool invocations and English tool brackets" do
      en(fn ->
        assert Text.scrub("Vexattack on Training Golem with shortbow d20: +5 vs", "Vex") == ""
        assert Text.scrub("I remember rolling a d20 in another life.", "Vex") =~ "d20"

        assert Text.scrub("I use spawn_monster(\"goblin\", \"g1\") for the ambush.", "dm") ==
                 "I use for the ambush."

        assert Text.scrub(
                 "Good. **[Establish fact: Thane accepted the mission.]** And now...",
                 "dm"
               ) ==
                 "Good. And now..."
      end)
    end

    test "drops English meta phrases and fourth-wall breaks" do
      en(fn ->
        assert Text.scrub("The scene resets. The group moves on.", "dm") == "The group moves on."
        assert Text.scrub("I materialize it in the world so it's official.", "dm") == ""
        assert Text.scrub("As the DM, I decide it rains.", "dm") == ""

        assert Text.scrub("The system resolves the attack. The goblin falls.", "dm") ==
                 "The goblin falls."

        meta =
          Text.scrub("The success of the check brings back her memory. The cold dries.", "Lyra")

        refute meta =~ "success of the check"
        assert meta =~ "The cold dries."
      end)
    end

    test "a sentence carrying the engine's DM turn cue is dropped, the fiction stays" do
      en(fn ->
        raw =
          "It's YOUR turn (DM) and you've already narrated the silence after the fight. " <>
            "The loft remains: the ladder creaks and the blue chest waits above."

        assert Text.scrub(raw) ==
                 "The loft remains: the ladder creaks and the blue chest waits above."

        text = "Thane waits his turn by the door while Mira counts the sacks."
        assert Text.scrub(text) == text
      end)
    end
  end

  describe "PC beats" do
    test "strips time skips and NPC voices while keeping the PC's own words" do
      en(fn ->
        skip =
          Text.scrub("I nod. Half an hour later you reach the tower. The cold bites.", "Thane")

        refute skip =~ ~r/half an hour/i
        assert skip == "I nod. The cold bites."

        voice =
          Text.scrub(
            "I walk up to the bar. —Head to the back —says the innkeeper. I wait for his nod.",
            "Thane"
          )

        refute voice =~ "says the innkeeper"
        assert voice =~ "I walk up to the bar"
        assert voice =~ "I wait for his nod"

        own = Text.scrub("—What's cooking? —I ask the innkeeper.", "Thane")
        assert own == "—What's cooking? —I ask the innkeeper."

        borin =
          Text.scrub(
            "I leave a coin. The innkeeper lowers his voice: \"Strange, two hooded men came by last night.\" I wait.",
            "Thane"
          )

        refute borin =~ "hooded men"
        assert borin =~ "I leave a coin"
      end)
    end

    test "subject-first, named and relative NPC replies are foreign speech" do
      en(fn ->
        for raw <- [
              "I stay by the table. \"Wait here,\" the innkeeper says.",
              "I stay by the table. Borin says: \"Wait here.\"",
              "I stay by the table. \"Wait here,\" says Borin."
            ] do
          clean = Text.scrub(raw, "Lyra", pc_names: ["Lyra", "Vex"])
          assert clean =~ "I stay by the table."
          refute clean =~ ~r/says/
        end

        assert Text.scrub("I walk up to the innkeeper, who replies: \"Close the door.\"", "Vex",
                 pc_names: ["Lyra", "Vex"]
               ) == "I walk up to the innkeeper"

        own = "—I'd rather wait —says Lyra."
        assert Text.scrub(own, "Lyra", pc_names: ["Lyra", "Vex"]) == own
      end)
    end

    test "addressing an NPC role and figurative observations stay in the PC's voice" do
      en(fn ->
        for raw <- [
              "—Thank you —I say to the innkeeper—. I wait for her answer.",
              "I hand the pouch to the innkeeper: \"Here are your seeds.\"",
              "The light tells me the time of day.",
              "The reflection answers my question."
            ] do
          assert Text.scrub(raw, "Vex", pc_names: ["Lyra", "Vex"], wait_for_human: true) == raw
        end

        clean =
          Text.scrub("I raise the jug. The innkeeper raises an arm: \"Come to the yard.\"", "Vex")

        assert clean =~ "I raise the jug."
        refute clean =~ "Come to the yard"
      end)
    end

    test "cuts a shouted NPC line" do
      en(fn ->
        out =
          Text.scrub(
            "Steel hisses. The man draws a dagger and the dwarf Borin ducks behind the bar shouting: —Look out!",
            "Thane"
          )

        refute out =~ "Look out"
        refute out =~ "shouting"
        assert out =~ "Steel hisses"
      end)
    end

    test "strips solo execution from an AI PC when a human is at the table" do
      en(fn ->
        out =
          Text.scrub(
            "I walk to the bar. She slides her nail under the wax and unrolls the scroll. What do you think, Thane?",
            "Lyra",
            wait_for_human: true
          )

        refute out =~ "unrolls"
        refute out =~ "wax"
        assert out == "I walk to the bar. What do you think, Thane?"

        kept = Text.scrub("She slides her nail under the wax and unrolls the scroll.", "Lyra")
        assert kept =~ "unrolls"

        light = "The light breaks in the jug. The wind sings."
        assert Text.scrub(light, "Lyra", wait_for_human: true) == light

        cut =
          Text.scrub("I look at the seal and break the wax. The wind sings.", "Lyra",
            wait_for_human: true
          )

        refute cut =~ "break the wax"
        assert cut =~ "The wind sings."
      end)
    end
  end
end
