defmodule Dragones.SpellSlotsTest do
  @moduledoc """
  Spell slot tracking: casters get limited slots per level; cantrips are free;
  long rest restores slots; backward compat (untracked worlds cast freely).
  """

  use ExUnit.Case, async: true

  alias Dragones.{Actions, Character, SpellSlots, World}

  defp fixed(value), do: Dragones.Dice.always(value)

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
          %Dragones.Weapon{
            name: "quarterstaff",
            dice: "1d6",
            damage_type: "bludgeoning",
            attack_ability: :str
          }
        ],
        spells: [
          %Dragones.Spell{
            name: "fire bolt",
            level: 0,
            kind: :attack,
            casting_ability: :int,
            dice: "1d10",
            damage_type: "fire"
          },
          %Dragones.Spell{
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
            %Dragones.Spell{
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
