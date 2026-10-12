defmodule Dragonex.LevelUpResourcesTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, Rest, SpellSlots, World}

  defp caster(class, level \\ 1) do
    {:ok, sheet} =
      Heroes.build(%{name: "Lyra", race: "human", class: class, background: "sage", level: level})

    sheet
  end

  defp spent_world(sheet, slot, times) do
    world = World.new(characters: %{sheet.name => sheet}) |> World.init_spell_slots()

    Enum.reduce(1..times, world, fn _, w ->
      {:ok, next} = World.consume_slot(sheet.name, slot).(w)
      next
    end)
  end

  test "a wizard gains only the new capacity after spending both level-one slots" do
    sheet = caster("wizard")
    before = spent_world(sheet, 1, 2)
    assert before.spell_slots[sheet.name] == %{1 => 0}
    assert {:ok, leveled} = World.level_up(sheet.name).(before)
    assert leveled.spell_slots[sheet.name] == %{1 => 1}
    assert leveled.characters[sheet.name].level == 2
    assert leveled.characters[sheet.name].hp == sheet.hp
    assert leveled.characters[sheet.name].max_hp > sheet.max_hp
  end

  test "new spell levels start available while old-level spending remains" do
    before = spent_world(caster("wizard", 2), 1, 2)
    assert before.spell_slots["Lyra"] == %{1 => 1}
    assert {:ok, leveled} = World.level_up("Lyra").(before)
    assert leveled.spell_slots["Lyra"] == %{1 => 2, 2 => 2}
  end

  test "the same full-caster rule applies to clerics, druids, bards and sorcerers" do
    for class <- ~w(cleric druid bard sorcerer) do
      before = spent_world(caster(class), 1, 1)
      assert {:ok, leveled} = World.level_up("Lyra").(before)
      assert leveled.spell_slots["Lyra"] == %{1 => 2}, class
    end
  end

  test "a first half-caster level grants new slots and later levels keep the expenditure" do
    for class <- ~w(paladin ranger) do
      world = World.new(characters: %{"Lyra" => caster(class)}) |> World.init_spell_slots()
      assert world.spell_slots["Lyra"] == %{}
      assert {:ok, leveled} = World.level_up("Lyra").(world)
      assert leveled.spell_slots["Lyra"] == %{1 => 2}
      assert {:ok, spent} = World.consume_slot("Lyra", 1).(leveled)
      assert {:ok, next} = World.level_up("Lyra").(spent)
      assert next.spell_slots["Lyra"] == %{1 => 2}
    end
  end

  test "pact spending transfers when the slot level increases instead of refreshing the pool" do
    before = spent_world(caster("warlock", 2), 1, 1)
    assert before.spell_slots["Lyra"] == %{1 => 1}
    assert {:ok, leveled} = World.level_up("Lyra").(before)
    assert leveled.spell_slots["Lyra"] == %{2 => 1}
    refute Map.has_key?(leveled.spell_slots["Lyra"], 1)
  end

  test "an exhausted pact pool stays exhausted across a slot-level promotion" do
    before = spent_world(caster("warlock", 4), 2, 2)
    assert {:ok, leveled} = World.level_up("Lyra").(before)
    assert leveled.spell_slots["Lyra"] == %{3 => 0}
  end

  test "a larger pact pool adds capacity without restoring its spent slots" do
    before = spent_world(caster("warlock", 10), 5, 2)
    assert {:ok, leveled} = World.level_up("Lyra").(before)
    assert leveled.spell_slots["Lyra"] == %{5 => 1}
  end

  test "a library merge is idempotent and preserves spending, rest limits and transient state" do
    before = spent_world(caster("wizard"), 1, 1)

    before = %{
      before
      | rest_state: %{"Lyra" => %{"hit_dice_used" => 1, "last_long_rest_start" => 0}},
        elapsed_seconds: 100
    }

    assert {:ok, before} = World.apply_damage("Lyra", 3).(before)
    assert {:ok, before} = World.apply_condition("Lyra", "poisoned").(before)
    assert {:ok, new_sheet} = Heroes.apply_level_up(caster("wizard"))
    leveled = Games.merge_character_level_up(before, "Lyra", new_sheet)
    assert leveled.spell_slots["Lyra"] == %{1 => 2}
    assert leveled.characters["Lyra"].hp == before.characters["Lyra"].hp
    assert World.has_condition?(leveled, "Lyra", "poisoned")
    assert leveled.rest_state == before.rest_state
    assert leveled.elapsed_seconds == before.elapsed_seconds
    assert Rest.remaining(leveled, "Lyra") == 1
    assert {:error, _} = Rest.validate(leveled, "Lyra", :long)
    assert Games.merge_character_level_up(leveled, "Lyra", new_sheet) == leveled
    assert Codec.decode(Codec.encode(leveled)) == leveled
  end

  test "an unchanged caster capacity does not refund anything" do
    before = spent_world(caster("wizard", 11), 1, 2)
    assert {:ok, leveled} = World.level_up("Lyra").(before)
    assert leveled.spell_slots["Lyra"] == before.spell_slots["Lyra"]
  end

  test "untracked legacy casters gain the full new capacity and non-casters keep no slot entry" do
    world = World.new(characters: %{"Lyra" => caster("wizard")})
    assert {:ok, leveled} = World.level_up("Lyra").(world)
    assert leveled.spell_slots["Lyra"] == %{1 => 3}

    fighter = Character.new(name: "Thane", class: "fighter", level: 1, hp: 12, max_hp: 12)
    assert {:ok, leveled} = World.level_up("Thane").(World.new(characters: %{"Thane" => fighter}))
    refute Map.has_key?(leveled.spell_slots, "Thane")
  end

  test "a missing level inside a tracked pool remains spent instead of being treated as untracked" do
    world = World.new(characters: %{"Lyra" => caster("wizard")}, spell_slots: %{"Lyra" => %{}})
    assert {:ok, leveled} = World.level_up("Lyra").(world)
    assert leveled.spell_slots["Lyra"] == %{1 => 1}
  end

  test "funded sorcery slots beyond the daily table survive the progression" do
    for {level, slot, expected} <- [
          {2, 1, %{1 => 5, 2 => 2}},
          {7, 5, %{1 => 4, 2 => 3, 3 => 3, 4 => 2, 5 => 1}}
        ] do
      sheet = caster("sorcerer", level)
      world = World.new(characters: %{sheet.name => sheet}) |> World.init_spell_slots()
      assert {:ok, _message, create} = Actions.create_spell_slot(world, sheet.name, slot)
      assert {:ok, funded} = create.(world)
      assert funded.characters[sheet.name].sorcery_points == 0
      assert {:ok, leveled} = World.level_up(sheet.name).(funded)
      assert leveled.spell_slots[sheet.name] == expected
      # D126: el gasto sigue comprometido; el nivel nuevo añade un solo punto.
      assert leveled.characters[sheet.name].sorcery_points == 1
    end
  end

  test "a real long rest restores full capacity after the progression rather than the level-up" do
    before = spent_world(caster("wizard"), 1, 2)
    assert {:ok, leveled} = World.level_up("Lyra").(before)
    assert leveled.spell_slots["Lyra"] == %{1 => 1}
    assert {:ok, _message, change} = Actions.long_rest(leveled, "Lyra")
    assert {:ok, rested} = change.(leveled)
    assert rested.spell_slots["Lyra"] == SpellSlots.for_class("wizard", 2)
  end

  test "an obsolete library sheet cannot lower a progressed world or its reserves" do
    before = spent_world(caster("wizard", 3), 2, 1)
    obsolete = caster("wizard", 2)
    assert Games.merge_character_level_up(before, "Lyra", obsolete) == before
  end
end
