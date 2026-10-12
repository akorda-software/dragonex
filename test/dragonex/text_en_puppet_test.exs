defmodule Dragonex.TextEnPuppetTest do
  @moduledoc """
  English counterpart of the puppeting suites (dialogue, clitic/adverb
  agency, collective agency, implicit movement, group decisions, name forms):
  the DM or another PC must not act, decide or speak for a PC.
  """
  use ExUnit.Case, async: true

  alias Dragonex.I18n
  alias Dragonex.Text

  @pcs ["Lyra", "Vex", "Thane"]
  @six ["Iria of the Dawn", "Lyra", "Mara of the Mist", "Nera of the Road", "Thane", "Vex"]
  @party ["Sylvi of the Oak", "Lyra", "Vex"]

  defp en(fun), do: I18n.with_locale(:en, fun)

  describe "named PC actions" do
    test "the DM cannot narrate a PC's proactive action; passive states stay" do
      en(fn ->
        out =
          Text.scrub(
            "Lyra walks up to the board and reads the notice. The fire crackles in the hearth.",
            "dm",
            pc_names: ["Lyra", "Thane"]
          )

        assert out == "The fire crackles in the hearth."

        for raw <- [
              "Lyra is wounded by the fence.",
              "Lyra falls wounded from the blow.",
              "Next to Lyra, the innkeeper opens the back door.",
              "Lyra takes 5 damage from the blast."
            ] do
          assert Text.scrub(raw, "dm", pc_names: ["Lyra"]) == raw
          refute Text.dm_puppets_pc?(raw, ["Lyra"])
        end
      end)
    end

    test "speech, decisions, nods and adverb-qualified actions are cut" do
      en(fn ->
        for action <- [
              "draws his sword",
              "says that she agrees",
              "replies with a smile",
              "decides to stay",
              "nods slowly",
              "quietly gathers them up",
              "already accepts the deal",
              "slowly picks it up",
              "takes the key from the table"
            ],
            actor <- ["dm", "Lyra"] do
          raw = "Iria #{action}. The door stays closed."
          assert Text.scrub(raw, actor, pc_names: @six) == "The door stays closed."
          assert Text.puppets_pc?(raw, actor, @six)
          assert Text.dm_puppets_pc?(raw, @six)
        end
      end)
    end

    test "the active PC keeps its own actions; NPC predicates stay" do
      en(fn ->
        own = "The room is calm. Iria quietly gathers them up, nodding."
        assert Text.scrub(own, "Iria of the Dawn", pc_names: @six) == own
        refute Text.puppets_pc?(own, "Iria of the Dawn", @six)

        for raw <- [
              "Iria is wounded while Sena gathers them.",
              "The jug gathers the light next to Iria.",
              "Sena gathers them in silence, and the warmth comes from the kitchen.",
              "Sena asks: \"Does Iria gather them or prefer to wait?\""
            ] do
          assert Text.scrub(raw, "dm", pc_names: @six, character_names: @six ++ ["Sena"]) == raw
          refute Text.puppets_pc?(raw, "dm", @six, @six ++ ["Sena"])
        end
      end)
    end

    test "an environmental tail survives while a coordinated object stays removed" do
      en(fn ->
        assert Text.scrub(
                 "Iria gathers them in silence, and the warmth of the kitchen drifts through the door.",
                 "dm",
                 pc_names: @six
               ) == "The warmth of the kitchen drifts through the door."

        assert Text.scrub(
                 "Iria gathers them, and puts them away carefully. The door creaks.",
                 "dm",
                 pc_names: @six
               ) == "The door creaks."
      end)
    end

    test "relative and subordinate PC actions are cut locally" do
      en(fn ->
        for actor <- ["dm", "Iria of the Dawn"] do
          clean =
            Text.scrub(
              "I look toward Lyra, who keeps leafing through the book, and ask about the seal. Nera of the Road, who tunes her bow, waits by the door.",
              actor,
              pc_names: @six
            )

          assert clean ==
                   "I look toward Lyra and ask about the seal. Nera of the Road waits by the door."
        end

        pcs = ["Sira of the Spark", "Iria of the Dawn"]

        clean =
          Text.scrub("The air hums while Sira casts fire, and Sena closes the door.", "dm",
            pc_names: pcs,
            character_names: pcs ++ ["Sena"]
          )

        refute clean =~ "casts"
        assert clean =~ "The air hums"
        assert clean =~ "Sena closes the door"

        assert Text.dm_puppets_pc?("When Sira drops the book, the door creaks.", pcs)
      end)
    end

    test "passive relatives and later NPC actions stay" do
      en(fn ->
        for raw <- [
              "Lyra is wounded while Sena opens the door.",
              "Vex stays next to Sena, who replies: \"You can rest.\"",
              "Lyra keeps silent while Sena speaks.",
              "I ask Lyra, who is wounded, whether she wants to rest."
            ],
            actor <- ["dm", "Thane"] do
          assert Text.scrub(raw, actor, pc_names: @pcs) == raw
          refute Text.dm_puppets_pc?(raw, @pcs)
        end
      end)
    end

    test "appositions are detected and ambiguous short names do not infer ownership" do
      en(fn ->
        assert Text.dm_puppets_pc?("Lyra, the elf mage, raises an eyebrow.", @pcs)
        assert Text.dm_puppets_pc?("Nera of the Road tunes the bow.", @six)

        sira = "Sira of the Spark"
        refute Text.dm_puppets_pc?("Sira raises an eyebrow.", [sira], [sira, "Sira of the Dock"])

        raw = "Sira closes her eyes. \"I want to study the reserve,\" says Sira."
        assert Text.scrub(raw, sira, pc_names: [sira, "Iria of the Dawn"]) == raw
      end)
    end
  end

  describe "PC speech" do
    test "a PC keeps its own voice while another PC's gesture and implicit speech go" do
      en(fn ->
        raw =
          "I raise an eyebrow. \"I'd study the map.\" Vex nods. \"Let's go now.\" The inn is calm."

        assert Text.scrub(raw, "Lyra", pc_names: @pcs) ==
                 "I raise an eyebrow. \"I'd study the map.\" The inn is calm."
      end)
    end

    test "verb-first and name-first attributions decide whose voice it is" do
      en(fn ->
        for raw <- [
              "\"My opinion,\" says Lyra. \"We all accept,\" comments Vex.",
              "\"My opinion,\" Lyra says. \"We all accept,\" Vex comments."
            ] do
          clean = Text.scrub(raw, "Lyra", pc_names: @pcs)
          assert clean =~ "My opinion"
          refute clean =~ "We all accept"
        end

        clean =
          Text.scrub("\"I accept the job,\" says Lyra. The door creaks.", "dm", pc_names: @pcs)

        assert clean == "The door creaks."
      end)
    end

    test "implicit and pronoun attributions belong to the removed PC until an NPC speaks" do
      en(fn ->
        raw =
          "Lyra raises an eyebrow. \"Let's leave now.\" —she comments. \"You decide, Iria.\" —she adds. \"Come back soon,\" says Sena. The door creaks."

        clean = Text.scrub(raw, "dm", pc_names: @six)
        refute clean =~ "Let's leave"
        refute clean =~ "You decide"
        assert clean =~ "\"Come back soon,\" says Sena."
        assert clean =~ "The door creaks."

        clean =
          Text.scrub(
            "Lyra raises an eyebrow. \"Let's leave now,\" she says. The door creaks.",
            "dm",
            pc_names: @pcs
          )

        assert clean == "The door creaks."
      end)
    end

    test "NPC quotations and responses after a removed PC action are preserved" do
      en(fn ->
        text = "Borin warns: \"Don't open the door.\" Lyra is wounded by the fire."
        assert Text.scrub(text, "dm", pc_names: @pcs) == text

        clean =
          Text.scrub(
            "Lyra approaches the board. \"Come back soon,\" says Borin. The fire crackles.",
            "dm",
            pc_names: @pcs
          )

        assert clean == "\"Come back soon,\" says Borin. The fire crackles."

        refute Text.scrub("Lyra comments: \"Let's go.\" What does Thane do?", "dm",
                 pc_names: @pcs
               ) =~
                 "Let's go"

        assert Text.scrub("Sena comments: \"What does Thane do?\"", "dm", pc_names: @pcs) =~
                 "Sena comments"
      end)
    end

    test "compound names are escaped and quoted references remain world narration" do
      en(fn ->
        clean =
          Text.scrub("Borin says: \"Ready?\" Ana (II) nods. The sign reads \"Ana (II)\".", "dm",
            pc_names: ["Ana (II)"]
          )

        refute clean =~ "Ana (II) nods"
        assert clean =~ "The sign reads \"Ana (II)\""
      end)
    end
  end

  describe "collective agency" do
    test "explicit party subjects and committed plural movement cannot act for other PCs" do
      en(fn ->
        for actor <- ["dm", "Lyra"],
            action <- [
              "The group crosses the threshold.",
              "**The group** crosses the threshold.",
              "The party advances toward the forest.",
              "The team approaches the altar.",
              "The adventurers accept the job.",
              "You all cross the bridge.",
              "Both of you decide to leave the room.",
              "You decide to leave the room.",
              "We approach the oak.",
              "We decide to accept the job.",
              "We leave the inn."
            ] do
          raw = action <> " The bird sings at the window."
          assert Text.scrub(raw, actor, pc_names: @party) == "The bird sings at the window."
          assert Text.dm_puppets_pc?(raw, @party)
        end
      end)
    end

    test "NPC groups, passive consequences, singular narration, plans and invitations stay" do
      en(fn ->
        for raw <- [
              "The group of guards crosses the bridge.",
              "The adventurers of the Council accept the job.",
              "The group is wounded by the fire.",
              "The group falls to the ground from the jolt.",
              "You see the oak from the window.",
              "You cross the bridge.",
              "The group can cross the bridge if it wants.",
              "If the group crosses the threshold, it will find the garden.",
              "Do you decide to leave the room?",
              "I propose we leave the room. What do you think?"
            ],
            actor <- ["dm", "Lyra"] do
          assert Text.scrub(raw, actor, pc_names: @party) == raw
          refute Text.dm_puppets_pc?(raw, @party)
        end

        # NPC voice is the DM's: quoted plural wording inside it stays.
        for raw <- [
              "Sena says: \"You all cross whenever you like.\"",
              "\"You decide to stay,\" says Sena."
            ] do
          assert Text.scrub(raw, "dm", pc_names: @party) == raw
          refute Text.dm_puppets_pc?(raw, @party)
        end
      end)
    end

    test "a solo PC keeps its collective wording and a completed quote does not shelter" do
      en(fn ->
        assert Text.scrub("We leave the room.", "Lyra", pc_names: ["Lyra"]) ==
                 "We leave the room."

        assert Text.scrub("The group advances.", "dm") == "The group advances."
        assert Text.puppets_pc?("Lyra approaches the oak.", "dm", @party)
        refute Text.puppets_pc?("Lyra approaches the oak.", "Lyra", @party)

        raw = "Sena says: \"Wait!\" The group crosses the threshold. The oak sways."

        assert Text.scrub(raw, "dm", pc_names: @party, character_names: @party ++ ["Sena"]) ==
                 "Sena says: \"Wait!\" The oak sways."
      end)
    end

    test "a group decision cannot be declared for the PCs" do
      en(fn ->
        for actor <- ["dm", "Lyra"],
            decision <- [
              "The decision is made between you: we'll go to the village.",
              "The decision has already been made among you.",
              "The decision was taken between you without debate."
            ] do
          assert Text.scrub(decision <> " The door stays closed.", actor, pc_names: @party) ==
                   "The door stays closed."
        end

        for raw <- [
              "The decision is made between the guards: they'll go to the village.",
              "Is the decision made between you?",
              "If the decision is made between you, tell Sena.",
              "Sena says: \"The decision is made between you.\"",
              "Do you exchange glances?",
              "I propose we look at each other for a moment before speaking.",
              "I look at Lyra and wait for her answer."
            ] do
          assert Text.scrub(raw, "dm", pc_names: @party) == raw
          refute Text.puppets_pc?(raw, "dm", @party)
          refute Text.dm_puppets_pc?(raw, @party)
        end
      end)
    end

    test "a human's declaration loses only the companions' borrowed gesture" do
      en(fn ->
        pcs = ["Mara of the Mist", "Lyra", "Vex"]

        raw =
          "I stay by the window, and you all exchange glances for a moment. —Lyra, Vex, would you rather walk to the village?"

        clean = Text.scrub(raw, "Mara of the Mist", pc_names: pcs)

        assert clean ==
                 "I stay by the window. —Lyra, Vex, would you rather walk to the village?"

        assert Text.puppets_pc?(raw, "Mara of the Mist", pcs)
        assert Text.scrub(clean, "Mara of the Mist", pc_names: pcs) == clean
      end)
    end
  end

  describe "implicit plural movement" do
    test "an affirmed approach loses only its trigger and destination" do
      en(fn ->
        for movement <- [
              "As you approach the oak,",
              "As you venture into the garden,",
              "As you head toward the window,",
              "As we move away from the door,",
              "As we leave the inn,",
              "As we step away from the path,"
            ],
            actor <- ["dm", "Lyra"] do
          raw = movement <> " the bird sings. The window stays closed."

          assert Text.scrub(raw, actor, pc_names: @party) ==
                   "The bird sings. The window stays closed."

          assert Text.puppets_pc?(raw, actor, @party)
          assert Text.dm_puppets_pc?(raw, @party)
        end
      end)
    end

    test "NPC speech, questions and conditional invitations are preserved" do
      en(fn ->
        for raw <- [
              "Sena says: \"As you approach the oak, you'll see the nest.\"",
              "\"As you approach the oak, you'll see the nest,\" says Sena.",
              "Sena says: \"As you approach the oak",
              "As you approach the oak, would you look for the nest?",
              "If you decide to leave, as you approach the oak you'll see the nest.",
              "You could look at the nest as you approach the oak.",
              "I propose examining the nest as we approach the oak.",
              "The jay sings as it approaches the oak.",
              "As the rain falls, the oak darkens."
            ] do
          assert Text.scrub(raw, "dm", pc_names: @party, character_names: @party ++ ["Sena"]) ==
                   raw

          refute Text.puppets_pc?(raw, "dm", @party, @party ++ ["Sena"])
          refute Text.dm_puppets_pc?(raw, @party, @party ++ ["Sena"])
        end
      end)
    end

    test "NPC quotes do not shelter the movement that follows them" do
      en(fn ->
        names = @party ++ ["Sena"]
        raw = "Sena asks: \"Are you waiting here?\" As you approach the oak, the bird sings."

        assert Text.scrub(raw, "dm", pc_names: @party, character_names: names) ==
                 "Sena asks: \"Are you waiting here?\" The bird sings."

        for quote <- ["Are you waiting here?", "If you want, wait here"] do
          raw = "Sena says: \"#{quote}\", and as you approach the oak, the bird sings."

          assert Text.scrub(raw, "dm", pc_names: @party, character_names: names) ==
                   "Sena says: \"#{quote}\", and the bird sings."
        end
      end)
    end

    test "a solo PC and the narrator's singular movement keep their own actions" do
      en(fn ->
        raw = "As we approach the oak, the bird sings."
        assert Text.scrub(raw, "Lyra", pc_names: ["Lyra"]) == raw
        assert Text.scrub(raw, "dm") == raw
        own = "As I approach the oak, I see the nest."
        assert Text.scrub(own, "Lyra", pc_names: @party) == own
      end)
    end
  end

  test "strip_puppet_clauses applies the English lexicon" do
    en(fn ->
      assert Text.strip_puppet_clauses("Thane charges the goblin. The torch gutters.", @pcs) ==
               "The torch gutters."
    end)
  end
end
