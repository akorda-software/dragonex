defmodule Dragonex.SpellSlotsTest do
  @moduledoc """
  Spell slot tracking: casters get limited slots per level; cantrips are free;
  long rest restores slots; backward compat (untracked worlds cast freely).
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, SpellSlots, World}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp wizard_world do
    wiz =
      Character.new(
        name: "Lyra",
        class: "wizard",
        hp: 8,
        max_hp: 8,
        ac: 10,
        str: 8,
        dex: 14,
        con: 14,
        int: 16,
        wis: 12,
        cha: 10,
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
          %Dragonex.Spell{
            name: "fire bolt",
            level: 0,
            kind: :attack,
            casting_ability: :int,
            dice: "1d10",
            damage_type: "fire"
          },
          %Dragonex.Spell{
            name: "magic missile",
            level: 1,
            kind: :automatic,
            casting_ability: :int,
            dice: "3d4+3",
            damage_type: "force"
          }
        ],
        side: "pc"
      )

    gob = Character.new(name: "goblin", class: "monster", hp: 7, max_hp: 7, ac: 15, side: "enemy")

    world =
      World.new()
      |> add(World.add_character(wiz))
      |> add(World.add_character(gob))

    World.init_spell_slots(world)
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end

  describe "SpellSlots.for_class/2" do
    test "level 1 wizard gets 2 level-1 slots" do
      assert SpellSlots.for_class("wizard", 1) == %{1 => 2}
    end

    test "level 3 cleric gets 4×1 + 2×2" do
      assert SpellSlots.for_class("cleric", 3) == %{1 => 4, 2 => 2}
    end

    test "level 1 fighter gets no slots" do
      assert SpellSlots.for_class("fighter", 1) == %{}
    end

    test "level 2 paladin (half caster) gets 2×1" do
      assert SpellSlots.for_class("paladin", 2) == %{1 => 2}
    end

    test "level 1 paladin (half caster) gets no slots" do
      assert SpellSlots.for_class("paladin", 1) == %{}
    end

    test "level 5 wizard gets up to level 3" do
      assert SpellSlots.for_class("wizard", 5) == %{1 => 4, 2 => 3, 3 => 2}
    end

    test "warlock Pact Magic table (PHB 5.1)" do
      assert SpellSlots.for_class("warlock", 1) == %{1 => 1}
      assert SpellSlots.for_class("warlock", 2) == %{1 => 2}
      assert SpellSlots.for_class("warlock", 3) == %{2 => 2}
      assert SpellSlots.for_class("warlock", 5) == %{3 => 2}
      assert SpellSlots.for_class("warlock", 11) == %{5 => 3}
      assert SpellSlots.for_class("warlock", 17) == %{5 => 4}
    end

    test "warlock is a caster from L1 but not a full caster" do
      assert SpellSlots.caster?("warlock")
      assert SpellSlots.pact_caster?("warlock")
      refute SpellSlots.full_caster?("warlock")
    end

    test "slot_level_for remaps warlock spells to the pact slot" do
      assert SpellSlots.slot_level_for("warlock", 5, 1) == 3
      assert SpellSlots.slot_level_for("warlock", 5, 3) == 3
      assert SpellSlots.slot_level_for("warlock", 5, 4) == 4
      assert SpellSlots.slot_level_for("wizard", 5, 1) == 1
    end
  end

  describe "World.init_spell_slots/1" do
    test "initializes slots for casters only" do
      w = wizard_world()

      assert w.spell_slots["Lyra"] == %{1 => 2}
      # goblin is not a caster → no entry
      refute Map.has_key?(w.spell_slots, "goblin")
    end
  end

  describe "Actions.spell slot enforcement" do
    test "cantrip (level 0) is always free — no slot consumed" do
      w = wizard_world()
      slots_before = w.spell_slots["Lyra"][1]

      {:ok, _msg, change} = Actions.spell(w, "Lyra", "fire bolt", "goblin", fixed(15))
      {:ok, w2} = change.(w)

      assert w2.spell_slots["Lyra"][1] == slots_before
    end

    test "level-1 spell consumes one slot" do
      w = wizard_world()

      {:ok, _msg, change} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w2} = change.(w)

      assert w2.spell_slots["Lyra"][1] == 1
    end

    test "two casts exhaust the 2 slots, third is refused" do
      w = wizard_world()

      {:ok, _, c1} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w2} = c1.(w)

      {:ok, _, c2} = Actions.spell(w2, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w3} = c2.(w2)

      assert w3.spell_slots["Lyra"][1] == 0

      # Third cast: no slots left
      assert {:error, msg} = Actions.spell(w3, "Lyra", "magic missile", "goblin", fixed(1))
      assert msg =~ "casillas de hechizo de nivel 1"
    end

    test "cantrip still works when slots are exhausted" do
      w = wizard_world()

      {:ok, _, c1} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w2} = c1.(w)
      {:ok, _, c2} = Actions.spell(w2, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w3} = c2.(w2)

      # Slots exhausted but cantrip is free
      assert {:ok, _, _} = Actions.spell(w3, "Lyra", "fire bolt", "goblin", fixed(15))
    end
  end

  describe "Actions.long_rest restores slots" do
    test "long rest restores all slots to max" do
      w = wizard_world()

      {:ok, _, c1} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w2} = c1.(w)

      assert w2.spell_slots["Lyra"][1] == 1

      {:ok, _, c2} = Actions.long_rest(w2, "Lyra")
      {:ok, w3} = c2.(w2)

      assert w3.spell_slots["Lyra"][1] == 2
    end
  end

  defp warlock_world(level) do
    warlock =
      Character.new(
        name: "Hex",
        class: "warlock",
        hp: 10,
        max_hp: 10,
        ac: 13,
        str: 8,
        dex: 14,
        con: 14,
        int: 10,
        wis: 12,
        cha: 16,
        level: level,
        spells: [
          %Dragonex.Spell{
            name: "eldritch blast",
            level: 0,
            kind: :attack,
            casting_ability: :cha,
            dice: "1d10",
            damage_type: "force"
          },
          %Dragonex.Spell{
            name: "magic missile",
            level: 1,
            kind: :automatic,
            casting_ability: :cha,
            dice: "3d4+3",
            damage_type: "force"
          },
          %Dragonex.Spell{
            name: "banishment",
            level: 4,
            kind: :save,
            casting_ability: :cha,
            dice: nil,
            damage_type: nil
          }
        ],
        side: "pc"
      )

    gob = Character.new(name: "goblin", class: "monster", hp: 7, max_hp: 7, ac: 15, side: "enemy")

    world =
      World.new()
      |> add(World.add_character(warlock))
      |> add(World.add_character(gob))

    World.init_spell_slots(world)
  end

  describe "Pact Magic (warlock D40)" do
    test "L5 warlock casting 1st-level magic missile spends a 3rd-level pact slot" do
      w = warlock_world(5)

      assert w.spell_slots["Hex"] == %{3 => 2}
      refute Map.has_key?(w.spell_slots["Hex"], 1)
      assert World.has_slot?(w, "Hex", 1)

      {:ok, _msg, change} = Actions.spell(w, "Hex", "magic missile", "goblin", fixed(1))
      {:ok, w2} = change.(w)

      assert w2.spell_slots["Hex"] == %{3 => 1}
      refute Map.has_key?(w2.spell_slots["Hex"], 1)

      {:ok, _, c2} = Actions.spell(w2, "Hex", "magic missile", "goblin", fixed(1))
      {:ok, w3} = c2.(w2)

      assert w3.spell_slots["Hex"] == %{3 => 0}

      assert {:error, _msg} = Actions.spell(w3, "Hex", "magic missile", "goblin", fixed(1))
    end

    test "L5 warlock cannot cast a 4th-level spell" do
      w = warlock_world(5)
      refute World.has_slot?(w, "Hex", 4)
      assert {:error, _} = Actions.spell(w, "Hex", "banishment", "goblin", fixed(1))
      assert w.spell_slots["Hex"] == %{3 => 2}
    end

    test "short rest restores warlock pact slots, including at full HP" do
      w = warlock_world(5)
      {:ok, w} = World.consume_slot("Hex", 1).(w)
      assert w.spell_slots["Hex"] == %{3 => 1}

      {:ok, msg, change} = Actions.short_rest(w, "Hex", fixed(4))
      assert msg =~ "Casillas de pacto recuperadas"
      {:ok, w2} = change.(w)
      assert w2.spell_slots["Hex"] == %{3 => 2}
      assert w2.characters["Hex"].hp == 10
    end

    test "short rest does not restore wizard slots" do
      w = wizard_world()
      {:ok, _, c1} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w2} = c1.(w)
      assert w2.spell_slots["Lyra"][1] == 1

      {:ok, msg, change} = Actions.short_rest(w2, "Lyra", fixed(4))
      refute msg =~ "Casillas"
      {:ok, w3} = change.(w2)
      assert w3.spell_slots["Lyra"][1] == 1
    end

    test "long rest still restores wizard slots" do
      w = wizard_world()
      {:ok, _, c1} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
      {:ok, w2} = c1.(w)

      {:ok, _, c2} = Actions.long_rest(w2, "Lyra")
      {:ok, w3} = c2.(w2)
      assert w3.spell_slots["Lyra"][1] == 2
    end
  end

  describe "backward compat" do
    test "untracked world (no init_spell_slots) casts freely" do
      wiz =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 1,
          hp: 8,
          max_hp: 8,
          ac: 10,
          str: 8,
          dex: 14,
          con: 14,
          int: 16,
          wis: 12,
          cha: 10,
          spells: [
            %Dragonex.Spell{
              name: "magic missile",
              level: 1,
              kind: :automatic,
              casting_ability: :int,
              dice: "3d4+3",
              damage_type: "force"
            }
          ],
          side: "pc"
        )

      gob =
        Character.new(name: "goblin", class: "monster", hp: 7, max_hp: 7, ac: 15, side: "enemy")

      # World without init_spell_slots
      {:ok, w} = World.add_character(wiz).(World.new())
      {:ok, w} = World.add_character(gob).(w)

      # Should work even though no slots are tracked
      assert {:ok, _, _} = Actions.spell(w, "Lyra", "magic missile", "goblin", fixed(1))
    end
  end
end
