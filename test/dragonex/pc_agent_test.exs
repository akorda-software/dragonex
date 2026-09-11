defmodule Dragonex.PCAgentTest do
  @moduledoc """
  AI-controlled PCs use their own agent (not the DM), with a personality-driven
  prompt. They propose as themselves and resolve through the same tools.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Character, PCAgent, World}
  alias ExAgent.{Models.Test}

  describe "system_prompt/1" do
    test "includes the character's name, race, class" do
      c =
        Character.new(
          name: "Lyra",
          race: "elf",
          class: "wizard",
          level: 1,
          hp: 6,
          max_hp: 6,
          ac: 10,
          str: 8,
          dex: 14,
          con: 10,
          int: 16,
          wis: 12,
          cha: 10,
          weapons: [
            %Dragonex.Weapon{
              name: "quarterstaff",
              dice: "1d6",
              damage_type: "bludgeoning",
              attack_ability: :str
            }
          ],
          spells: [
            %Dragonex.Spell{
              name: "fire bolt",
              level: 0,
              kind: :attack,
              casting_ability: :int,
              dice: "1d10",
              damage_type: "fire"
            }
          ],
          side: "pc"
        )

      prompt = PCAgent.system_prompt(c)

      assert prompt =~ "Lyra"
      assert prompt =~ "elf"
      assert prompt =~ "mago"
      assert prompt =~ "quarterstaff"
      assert prompt =~ "fire bolt"
      assert prompt =~ "PERSONALIDAD"
      assert prompt =~ "MESA, NO SOLILOQUIO"
      refute prompt =~ "TOMA LA ACCIÓN directamente"
    end

    test "each class gets a distinct personality" do
      rogue = Character.new(name: "Vex", race: "halfling", class: "rogue", level: 1, side: "pc")
      paladin = Character.new(name: "Bryn", race: "human", class: "paladin", level: 1, side: "pc")

      rogue_prompt = PCAgent.system_prompt(rogue)
      paladin_prompt = PCAgent.system_prompt(paladin)

      assert rogue_prompt =~ "astuto"
      assert paladin_prompt =~ "honorable"
    end

    test "every playable class gets a distinct, non-default personality (regression)" do
      # All 12 SRD classes must have a dedicated class_personality/1 clause —
      # none should fall back to the generic default. Also pins the druid fix
      # (it used to bleed fighter copy: "artes marciales").
      classes =
        ~w(barbarian bard cleric druid fighter monk paladin ranger rogue sorcerer warlock wizard)

      default = "aventurero capaz con tus propias motivaciones"

      prompts =
        Map.new(classes, fn class ->
          c = Character.new(name: "X", race: "human", class: class, level: 1, side: "pc")
          {class, PCAgent.system_prompt(c)}
        end)

      # None fall back to the default...
      for {class, prompt} <- prompts do
        refute prompt =~ default, "class #{inspect(class)} fell back to the default personality"
      end

      # ...and the fixed druid no longer leaks fighter copy.
      refute prompts["druid"] =~ "artes marciales"
      assert prompts["druid"] =~ "naturaleza"

      # fighter and monk (previously missing) now have their own voice.
      assert prompts["fighter"] =~ "armas"
      assert prompts["monk"] =~ "energía interior"
    end
  end

  describe "instruction/3" do
    test "lists available weapons and spells in combat with enemies" do
      c =
        Character.new(
          name: "Thane",
          race: "human",
          class: "fighter",
          level: 1,
          weapons: [
            %Dragonex.Weapon{
              name: "longsword",
              dice: "1d8",
              damage_type: "slashing",
              attack_ability: :str
            },
            %Dragonex.Weapon{
              name: "javelin",
              dice: "1d6",
              damage_type: "piercing",
              attack_ability: :str
            }
          ],
          spells: [],
          side: "pc"
        )

      # A combat world with a living enemy so the bot is steered to make_attack.
      {:ok, w1} = World.add_character(c).(World.new())

      {:ok, w2} =
        World.add_character(%Character{name: "goblin", side: "enemy", hp: 7, max_hp: 7}).(w1)

      {:ok, world} = World.begin_combat(["Thane", "goblin"]).(w2)

      instr = PCAgent.instruction("Thane", c, world)

      assert instr =~ "longsword"
      assert instr =~ "javelin"
      assert instr =~ "Es TU turno"
      assert instr =~ "goblin"
      assert instr =~ "Objetivos VÁLIDOS"
    end

    test "in exploration (no enemies) steers the bot to act in character, no tools" do
      c =
        Character.new(
          name: "Thane",
          race: "human",
          class: "fighter",
          level: 1,
          weapons: [
            %Dragonex.Weapon{
              name: "longsword",
              dice: "1d8",
              damage_type: "slashing",
              attack_ability: :str
            }
          ],
          spells: [],
          side: "pc"
        )

      # Exploration world — only the PC, no enemies. The bot must NOT be told
      # to call make_attack on phantoms; it should act in character.
      {:ok, world} = World.add_character(c).(World.new())

      instr = PCAgent.instruction("Thane", c, world)

      assert instr =~ "Es TU turno"
      assert instr =~ "PERSONAJE ACTIVO"
      assert instr =~ "NO hay enemigos"
      assert instr =~ "espera"
      refute instr =~ "ejecútala"
      refute instr =~ "abre una puerta"
    end

    test "a downed (0 hp) PC is steered to make_death_save" do
      c =
        Character.new(
          name: "Thane",
          race: "human",
          class: "fighter",
          level: 1,
          hp: 0,
          max_hp: 12,
          side: "pc"
        )

      instr = PCAgent.instruction("Thane", c, World.new())

      assert instr =~ "CAÍDO"
      assert instr =~ "make_death_save"
    end

    test "a dead (3 fails) PC is NOT told to call make_death_save again" do
      c =
        Character.new(
          name: "Thane",
          race: "human",
          class: "fighter",
          level: 1,
          hp: 0,
          max_hp: 12,
          death_saves: %{successes: 0, fails: 3},
          side: "pc"
        )

      instr = PCAgent.instruction("Thane", c, World.new())

      assert instr =~ "MUERTO"
      # The dead branch must never hand the bot a death-save tool call.
      refute instr =~ "make_death_save(\"Thane\")"
    end

    test "includes spells for casters in combat" do
      c =
        Character.new(
          name: "Lyra",
          race: "elf",
          class: "wizard",
          level: 1,
          weapons: [
            %Dragonex.Weapon{
              name: "quarterstaff",
              dice: "1d6",
              damage_type: "bludgeoning",
              attack_ability: :str
            }
          ],
          spells: [
            %Dragonex.Spell{name: "fire bolt", level: 0, kind: :attack, casting_ability: :int}
          ],
          side: "pc"
        )

      {:ok, w1} = World.add_character(c).(World.new())

      {:ok, w2} =
        World.add_character(%Character{name: "goblin", side: "enemy", hp: 7, max_hp: 7}).(w1)

      {:ok, world} = World.begin_combat(["Lyra", "goblin"]).(w2)

      instr = PCAgent.instruction("Lyra", c, world)

      assert instr =~ "fire bolt"
      assert instr =~ "cast_spell"
    end
  end

  describe "new/3 builds a working agent" do
    test "the agent has the right instructions and tools" do
      c =
        Character.new(
          name: "Bryn",
          race: "human",
          class: "fighter",
          level: 1,
          weapons: [
            %Dragonex.Weapon{
              name: "longsword",
              dice: "1d8",
              damage_type: "slashing",
              attack_ability: :str
            }
          ],
          side: "pc"
        )

      agent = PCAgent.new(%Test{label: "test"}, c)

      instr = agent.instructions |> Enum.map(& &1.content) |> Enum.join("\n")
      assert instr =~ "Bryn"
      assert instr =~ "guerrero"
      assert length(agent.tools) > 0
    end

    test "PC tools are restricted — no DM-only tools" do
      tool_names = PCAgent.tools() |> Enum.map(& &1.name)

      # PC CAN use these
      assert "make_attack" in tool_names
      assert "cast_spell" in tool_names
      assert "ability_check" in tool_names
      assert "make_death_save" in tool_names
      assert "short_rest" in tool_names
      assert "long_rest" in tool_names
      assert "drop_concentration" in tool_names
      assert "start_rage" in tool_names
      assert "end_rage" in tool_names
      assert "start_reckless" in tool_names
      assert "end_reckless" in tool_names
      assert "second_wind" in tool_names
      assert "action_surge" in tool_names
      assert "divine_smite" in tool_names
      assert "end_smite" in tool_names

      # PC CANNOT use these (DM-only)
      refute "set_scene" in tool_names
      refute "spawn_monster" in tool_names
      refute "spawn_character" in tool_names
      refute "roll_initiative" in tool_names
      refute "end_combat" in tool_names
      refute "level_up" in tool_names
      refute "apply_condition" in tool_names
      refute "remove_condition" in tool_names
      refute "grant_temp_hp" in tool_names
      refute "grant_xp" in tool_names
      refute "heal" in tool_names
    end
  end
end
