defmodule Dragones.PCAgentTest do
  @moduledoc """
  AI-controlled PCs use their own agent (not the DM), with a personality-driven
  prompt. They propose as themselves and resolve through the same tools.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Character, PCAgent, World}
  alias ExAgent.{Models.Test}

  describe "system_prompt/1" do
    test "includes the character's name, race, class" do
      c = Character.new(
        name: "Lyra", race: "elf", class: "wizard", level: 1,
        hp: 6, max_hp: 6, ac: 10,
        str: 8, dex: 14, con: 10, int: 16, wis: 12, cha: 10,
        weapons: [%Dragones.Weapon{name: "quarterstaff", dice: "1d6", damage_type: "bludgeoning", attack_ability: :str}],
        spells: [%Dragones.Spell{name: "fire bolt", level: 0, kind: :attack, casting_ability: :int, dice: "1d10", damage_type: "fire"}],
        side: "pc"
      )

      prompt = PCAgent.system_prompt(c)

      assert prompt =~ "Lyra"
      assert prompt =~ "elf"
      assert prompt =~ "mago"
      assert prompt =~ "quarterstaff"
      assert prompt =~ "fire bolt"
      assert prompt =~ "PERSONALIDAD"
    end

    test "each class gets a distinct personality" do
      rogue = Character.new(name: "Vex", race: "halfling", class: "rogue", level: 1, side: "pc")
      paladin = Character.new(name: "Bryn", race: "human", class: "paladin", level: 1, side: "pc")

      rogue_prompt = PCAgent.system_prompt(rogue)
      paladin_prompt = PCAgent.system_prompt(paladin)

      assert rogue_prompt =~ "astuto"
      assert paladin_prompt =~ "honorable"
    end
  end

  describe "instruction/3" do
    test "lists available weapons and spells in combat with enemies" do
      c = Character.new(
        name: "Thane", race: "human", class: "fighter", level: 1,
        weapons: [
          %Dragones.Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str},
          %Dragones.Weapon{name: "javelin", dice: "1d6", damage_type: "piercing", attack_ability: :str}
        ],
        spells: [],
        side: "pc"
      )

      # A combat world with a living enemy so the bot is steered to make_attack.
      {:ok, w1} = World.add_character(c).(World.new())
      {:ok, w2} = World.add_character(%Character{name: "goblin", side: "enemy", hp: 7, max_hp: 7}).(w1)
      {:ok, world} = World.begin_combat(["Thane", "goblin"]).(w2)

      instr = PCAgent.instruction("Thane", c, world)

      assert instr =~ "longsword"
      assert instr =~ "javelin"
      assert instr =~ "Es TU turno"
      assert instr =~ "goblin"
      assert instr =~ "Objetivos VÁLIDOS"
    end

    test "in exploration (no enemies) steers the bot to act in character, no tools" do
      c = Character.new(
        name: "Thane", race: "human", class: "fighter", level: 1,
        weapons: [%Dragones.Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}],
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
    end

    test "includes spells for casters in combat" do
      c = Character.new(
        name: "Lyra", race: "elf", class: "wizard", level: 1,
        weapons: [%Dragones.Weapon{name: "quarterstaff", dice: "1d6", damage_type: "bludgeoning", attack_ability: :str}],
        spells: [%Dragones.Spell{name: "fire bolt", level: 0, kind: :attack, casting_ability: :int}],
        side: "pc"
      )

      {:ok, w1} = World.add_character(c).(World.new())
      {:ok, w2} = World.add_character(%Character{name: "goblin", side: "enemy", hp: 7, max_hp: 7}).(w1)
      {:ok, world} = World.begin_combat(["Lyra", "goblin"]).(w2)

      instr = PCAgent.instruction("Lyra", c, world)

      assert instr =~ "fire bolt"
      assert instr =~ "cast_spell"
    end
  end

  describe "new/3 builds a working agent" do
    test "the agent has the right instructions and tools" do
      c = Character.new(
        name: "Bryn", race: "human", class: "fighter", level: 1,
        weapons: [%Dragones.Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}],
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

      # PC CANNOT use these (DM-only)
      refute "set_scene" in tool_names
      refute "spawn_monster" in tool_names
      refute "spawn_character" in tool_names
      refute "roll_initiative" in tool_names
      refute "end_combat" in tool_names
      refute "level_up" in tool_names
      refute "apply_condition" in tool_names
      refute "remove_condition" in tool_names
    end
  end
end
