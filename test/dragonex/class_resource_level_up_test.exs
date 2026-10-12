defmodule Dragonex.ClassResourceLevelUpTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, World}

  defp hero(class, level \\ 1) do
    {:ok, sheet} =
      Heroes.build(%{name: "Ada", race: "human", class: class, level: level, background: "sage"})

    sheet
  end

  defp world(sheet),
    do: World.new(characters: %{sheet.name => sheet}) |> World.init_spell_slots()

  test "a monk who unlocks ki can spend the new pool without a rest" do
    sheet = hero("monk")
    assert sheet.ki == 0
    enemy = Character.new(name: "Dummy", hp: 30, max_hp: 30, side: "enemy")
    before = world(sheet)
    {:ok, before} = World.add_character(enemy).(before)
    assert {:ok, leveled} = World.level_up(sheet.name).(before)
    assert leveled.characters[sheet.name].ki == 2

    assert {:ok, _, change} =
             Actions.flurry_of_blows(leveled, sheet.name, enemy.name, fn _ -> 1 end)

    assert {:ok, spent} = change.(leveled)
    assert spent.characters[sheet.name].ki == 1
    assert spent.elapsed_seconds == before.elapsed_seconds
    assert spent.characters[sheet.name].hp == sheet.hp
  end

  test "a sorcerer who unlocks Font of Magic can pay for a slot without a rest" do
    sheet = hero("sorcerer")
    assert sheet.sorcery_points == 0
    assert {:ok, leveled} = World.level_up(sheet.name).(world(sheet))
    assert leveled.characters[sheet.name].sorcery_points == 2
    assert {:ok, _, change} = Actions.create_spell_slot(leveled, sheet.name, 1)
    assert {:ok, funded} = change.(leveled)
    assert funded.characters[sheet.name].sorcery_points == 0
    assert funded.spell_slots[sheet.name] == %{1 => 4}
    assert funded.elapsed_seconds == 0
  end

  test "a druid who unlocks Wild Shape can transform with its new uses" do
    sheet = hero("druid")
    assert sheet.wild_shape_uses == 0
    assert {:ok, leveled} = World.level_up(sheet.name).(world(sheet))
    assert leveled.characters[sheet.name].wild_shape_uses == 2
    assert {:ok, _, change} = Actions.wild_shape(leveled, sheet.name, "wolf")
    assert {:ok, transformed} = change.(leveled)
    assert transformed.characters[sheet.name].wild_shape_uses == 1
    assert transformed.characters[sheet.name].wild_shape.beast == "wolf"
    assert transformed.elapsed_seconds == 0
  end

  test "ki capacity increases by one while previously spent points stay spent" do
    sheet = hero("monk", 2)
    assert {:ok, exhausted} = World.spend_ki(sheet.name, 2).(world(sheet))
    assert {:ok, third} = World.level_up(sheet.name).(exhausted)
    assert third.characters[sheet.name].ki == 1
    assert {:ok, exhausted} = World.spend_ki(sheet.name, 1).(third)
    assert {:ok, fourth} = World.level_up(sheet.name).(exhausted)
    assert fourth.characters[sheet.name].ki == 1
    assert fourth.elapsed_seconds == 0
  end

  test "spent sorcery points gain only the new point while their funded slot survives" do
    sheet = hero("sorcerer", 2)
    before = world(sheet)
    assert {:ok, _, change} = Actions.create_spell_slot(before, sheet.name, 1)
    assert {:ok, funded} = change.(before)
    assert funded.characters[sheet.name].sorcery_points == 0
    assert {:ok, third} = World.level_up(sheet.name).(funded)
    assert third.characters[sheet.name].sorcery_points == 1
    assert third.spell_slots[sheet.name] == %{1 => 5, 2 => 2}
  end

  test "Lay on Hands gains the five new points without refunding a healing payment" do
    sheet = hero("paladin")
    assert {:ok, wounded} = World.apply_damage(sheet.name, 3).(world(sheet))
    assert {:ok, _, change} = Actions.lay_on_hands(wounded, sheet.name, sheet.name, 3)
    assert {:ok, healed} = change.(wounded)
    assert healed.characters[sheet.name].lay_on_hands_pool == 2
    assert {:ok, second} = World.level_up(sheet.name).(healed)
    assert second.characters[sheet.name].lay_on_hands_pool == 7
    assert second.characters[sheet.name].hp == healed.characters[sheet.name].hp
    assert second.elapsed_seconds == 0
  end

  test "a Charisma ASI expands bardic uses without refunding the old expenditure" do
    sheet = %{hero("bard", 3) | cha: 16, bardic_inspiration_uses: 0, inspired: true}
    assert {:ok, fourth} = World.level_up(sheet.name, %{asi: %{cha: 2}}).(world(sheet))
    assert fourth.characters[sheet.name].cha == 18
    assert fourth.characters[sheet.name].bardic_inspiration_uses == 1
    assert fourth.characters[sheet.name].inspired
    assert fourth.characters[sheet.name].hp == sheet.hp
  end

  test "a paladin Charisma ASI expands sense and healing capacity independently" do
    sheet = %{hero("paladin", 3) | cha: 16, divine_sense_uses: 0, lay_on_hands_pool: 11}
    assert {:ok, fourth} = World.level_up(sheet.name, %{asi: %{cha: 2}}).(world(sheet))
    assert fourth.characters[sheet.name].divine_sense_uses == 1
    assert fourth.characters[sheet.name].lay_on_hands_pool == 16
    assert fourth.characters[sheet.name].hp == sheet.hp
  end

  test "unchanged or capped Charisma and later druid levels do not refill uses" do
    for {class, old_cha, delta, field} <- [
          {"bard", 10, 1, :bardic_inspiration_uses},
          {"bard", 20, 2, :bardic_inspiration_uses},
          {"paladin", 10, 1, :divine_sense_uses},
          {"druid", 16, 2, :wild_shape_uses}
        ] do
      sheet = hero(class, 3) |> Map.put(:cha, old_cha) |> Map.put(field, 0)
      assert {:ok, leveled} = World.level_up(sheet.name, %{asi: %{cha: delta}}).(world(sheet))
      assert Map.fetch!(leveled.characters[sheet.name], field) == 0, class
    end
  end

  test "library merge uses the live expenditure, remains idempotent and survives the codec" do
    for {class, level, field, expected, choices} <- [
          {"monk", 2, :ki, 1, %{}},
          {"sorcerer", 2, :sorcery_points, 1, %{}},
          {"paladin", 1, :lay_on_hands_pool, 5, %{}},
          {"bard", 3, :bardic_inspiration_uses, 1, %{asi: %{cha: 2}}},
          {"paladin", 3, :divine_sense_uses, 1, %{asi: %{cha: 2}}},
          {"druid", 1, :wild_shape_uses, 2, %{}}
        ] do
      sheet = %{hero(class, level) | cha: 16}
      live = sheet |> Map.put(field, 0) |> Map.put(:hp, 2) |> Map.put(:temp_hp, 3)

      before = %{
        world(live)
        | elapsed_seconds: 100,
          rest_state: %{sheet.name => %{"hit_dice_used" => 1}}
      }

      assert {:ok, library} = Heroes.apply_level_up(sheet, choices)
      merged = Games.merge_character_level_up(before, sheet.name, library)
      assert Map.fetch!(merged.characters[sheet.name], field) == expected, class
      assert merged.characters[sheet.name].hp == 2
      assert merged.characters[sheet.name].temp_hp == 3
      assert merged.rest_state == before.rest_state
      assert merged.elapsed_seconds == before.elapsed_seconds
      assert Games.merge_character_level_up(merged, sheet.name, library) == merged
      assert Codec.decode(Codec.encode(merged)) == merged
    end
  end

  test "a real rest replenishes the full progressed pool after the spent uses were carried" do
    for {class, field, expected, rest} <- [
          {"monk", :ki, 3, :short},
          {"sorcerer", :sorcery_points, 3, :long},
          {"paladin", :lay_on_hands_pool, 15, :long},
          {"druid", :wild_shape_uses, 2, :short}
        ] do
      sheet = hero(class, 2) |> Map.put(field, 0)
      assert {:ok, progressed} = World.level_up(sheet.name).(world(sheet))

      result =
        if rest == :short,
          do: Actions.short_rest(progressed, sheet.name, fn _ -> 1 end, nil, 0),
          else: Actions.long_rest(progressed, sheet.name)

      assert {:ok, _, change} = result
      assert {:ok, rested} = change.(progressed)
      assert Map.fetch!(rested.characters[sheet.name], field) == expected, class
      assert rested.elapsed_seconds > progressed.elapsed_seconds
    end
  end

  test "other classes keep flags and unrelated resources without a rest" do
    sheet = %{
      hero("fighter")
      | second_wind_used: true,
        action_surge_used: true,
        channel_divinity_used: true,
        arcane_recovery_used: true,
        rage_uses_used: 2,
        wild_shape_uses: 0,
        ki: 0,
        sorcery_points: 0
    }

    assert {:ok, second} = Heroes.apply_level_up(sheet, %{})
    assert second.second_wind_used and second.action_surge_used
    assert second.channel_divinity_used and second.arcane_recovery_used
    assert second.rage_uses_used == 2
    assert second.wild_shape_uses == 0 and second.ki == 0 and second.sorcery_points == 0
  end
end
