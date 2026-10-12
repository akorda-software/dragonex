defmodule Dragonex.WildShapeLevelUpTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, Weapon, World}

  defp druid(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Sylvi",
          race: "human",
          class: "druid",
          level: 2,
          str: 10,
          dex: 14,
          con: 18,
          int: 12,
          wis: 16,
          cha: 10,
          hp: 7,
          max_hp: 20,
          ac: 12,
          wild_shape_uses: 2,
          weapons: [
            %Weapon{
              name: "quarterstaff",
              dice: "1d6",
              damage_type: "bludgeoning",
              attack_ability: :str
            }
          ]
        ],
        opts
      )
    )
  end

  defp transformed(sheet) do
    w = World.new(characters: %{sheet.name => sheet}) |> World.init_spell_slots()
    {:ok, _, change} = Actions.wild_shape(w, sheet.name, "wolf")
    {:ok, w} = change.(w)
    {:ok, w} = World.apply_damage(sheet.name, 5).(w)
    w
  end

  defp live(w), do: w.characters["Sylvi"]

  defp roundtrip(w),
    do: w |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()

  test "LevelUp uses the druid's original Constitution and preserves the damaged beast" do
    before = transformed(druid())
    beast = live(before)
    assert beast.hp == 6 and beast.max_hp == 11 and beast.con == 12
    assert {:ok, updated} = Heroes.apply_level_up(beast, %{})
    assert updated.level == 3
    assert updated.hp == 6 and updated.max_hp == 11
    assert updated.con == 12 and updated.dex == beast.dex
    assert updated.ac == beast.ac and updated.weapons == beast.weapons
    assert updated.wild_shape.orig_hp == 7
    assert updated.wild_shape.orig_max_hp == 29
    assert updated.wild_shape.orig_con == 18
    assert updated.wild_shape_uses == 1
  end

  test "World progression gains slots without rest and manual revert restores the progressed native form" do
    sheet = druid()
    before = transformed(sheet)
    {:ok, before} = World.consume_slot(sheet.name, 1).(before)

    before = %{
      before
      | elapsed_seconds: 99,
        rest_state: %{sheet.name => %{"hit_dice_used" => 1, "last_long_rest_start" => 0}}
    }

    assert {:ok, progressed} = World.level_up(sheet.name).(before)
    assert progressed.spell_slots[sheet.name] == %{1 => 3, 2 => 2}
    assert live(progressed).hp == 6 and live(progressed).max_hp == 11
    assert progressed.rest_state == before.rest_state
    assert progressed.elapsed_seconds == before.elapsed_seconds
    assert {:ok, reverted} = World.revert_wild_shape(sheet.name).(progressed)
    assert live(reverted).level == 3
    assert live(reverted).hp == 7 and live(reverted).max_hp == 29
    assert live(reverted).con == 18 and live(reverted).dex == 14
    assert live(reverted).ac == 12 and live(reverted).weapons == sheet.weapons
    assert live(reverted).wild_shape == nil
    assert live(reverted).wild_shape_uses == 1
  end

  test "library sync preserves the beast and updates the durable original form exactly once" do
    sheet = druid()
    before = transformed(sheet)
    assert {:ok, leveled_sheet} = Heroes.apply_level_up(sheet, %{})
    progressed = Games.merge_character_level_up(before, sheet.name, leveled_sheet)
    assert live(progressed).hp == 6 and live(progressed).max_hp == 11
    assert live(progressed).con == live(before).con
    assert live(progressed).dex == live(before).dex
    assert live(progressed).ac == live(before).ac
    assert live(progressed).weapons == live(before).weapons
    assert live(progressed).wild_shape.orig_max_hp == 29
    assert live(progressed).wild_shape.orig_hp == 7
    assert live(progressed).wild_shape_uses == 1
    assert Games.merge_character_level_up(progressed, sheet.name, leveled_sheet) == progressed
    loaded = roundtrip(progressed)
    assert loaded == progressed
    assert {:ok, reverted} = World.revert_wild_shape(sheet.name).(loaded)
    assert live(reverted).hp == 7 and live(reverted).max_hp == 29
    assert live(reverted).weapons == sheet.weapons
  end

  test "Constitution ASI changes native vitality without healing or changing the beast" do
    sheet = druid(level: 3, con: 17)
    before = transformed(sheet)
    assert {:ok, native} = Heroes.apply_level_up(sheet, %{asi: %{con: 2}})
    assert native.hp == 10 and native.max_hp == 32 and native.con == 19
    assert {:ok, progressed} = World.level_up(sheet.name, %{asi: %{con: 2}}).(before)
    merged = Games.merge_character_level_up(before, sheet.name, native)

    for w <- [progressed, merged] do
      assert live(w).hp == 6 and live(w).max_hp == 11 and live(w).con == 12
      assert live(w).wild_shape.orig_con == 19
      assert live(w).wild_shape.orig_hp == 10
      assert live(w).wild_shape.orig_max_hp == 32
      assert {:ok, reverted} = World.revert_wild_shape(sheet.name).(roundtrip(w))
      assert live(reverted).con == 19
      assert live(reverted).hp == 10 and live(reverted).max_hp == 32
    end
  end

  test "Dexterity ASI updates the native AC and keeps the active beast's scores and AC" do
    sheet = druid(level: 3)
    before = transformed(sheet)
    assert {:ok, native} = Heroes.apply_level_up(sheet, %{asi: %{dex: 2}})
    assert native.dex == 16 and native.ac == 13
    assert {:ok, progressed} = World.level_up(sheet.name, %{asi: %{dex: 2}}).(before)
    merged = Games.merge_character_level_up(before, sheet.name, native)

    for w <- [progressed, merged] do
      assert live(w).dex == live(before).dex
      assert live(w).ac == live(before).ac
      assert live(w).wild_shape.orig_dex == 16 and live(w).wild_shape.orig_ac == 13
      assert {:ok, reverted} = World.revert_wild_shape(sheet.name).(w)
      assert live(reverted).dex == 16 and live(reverted).ac == 13
    end
  end

  test "automatic revert carries only excess damage into the progressed native hit points" do
    before = transformed(druid())
    assert {:ok, progressed} = World.level_up("Sylvi").(before)
    assert {:ok, damaged} = World.apply_damage("Sylvi", 9).(roundtrip(progressed))
    assert live(damaged).wild_shape == nil
    assert live(damaged).hp == 4 and live(damaged).max_hp == 29
    assert live(damaged).con == 18
    assert live(damaged).wild_shape_uses == 1
  end

  test "mental ASI and newly learned spells survive the form without allowing casting as a beast" do
    sheet = druid(level: 3)
    before = transformed(sheet)
    {:ok, before} = World.apply_condition(sheet.name, "poisoned").(before)
    choices = %{asi: %{wis: 2}, spells_added: ["lesser restoration"]}
    assert {:ok, native} = Heroes.apply_level_up(sheet, choices)
    assert {:ok, progressed} = World.level_up(sheet.name, choices).(before)
    merged = Games.merge_character_level_up(before, sheet.name, native)

    for w <- [progressed, merged] do
      assert live(w).wis == 18
      assert live(w).str == live(before).str and live(w).con == live(before).con

      assert Enum.any?(
               live(w).spells,
               &(&1.name == "lesser restoration" and &1.casting_ability == :wis)
             )

      assert {:error, reason} =
               Actions.spell(w, sheet.name, "lesser restoration", sheet.name, fn _ ->
                 flunk("beast cannot cast")
               end)

      assert reason =~ "forma de bestia"

      assert {:ok, reverted} = World.revert_wild_shape(sheet.name).(roundtrip(w))
      assert live(reverted).wis == 18

      assert {:ok, _, cast} =
               Actions.spell(reverted, sheet.name, "lesser restoration", sheet.name, fn _ ->
                 flunk("no dice")
               end)

      assert {:ok, cured} = cast.(reverted)
      refute World.has_condition?(cured, sheet.name, "poisoned")
      assert cured.spell_slots[sheet.name][2] == 2
    end
  end

  test "a stale library sheet and max-level rejection cannot disturb either form" do
    sheet = druid()
    w = transformed(sheet)
    assert Games.merge_character_level_up(w, sheet.name, %{sheet | level: 1}) == w
    capped = %{w | characters: %{sheet.name => %{live(w) | level: 20}}}
    assert {:error, _} = World.level_up(sheet.name).(capped)
    assert live(capped).hp == 6 and live(capped).max_hp == 11
    assert live(capped).wild_shape.orig_hp == 7 and live(capped).wild_shape.orig_max_hp == 20
  end

  test "progressing midway through a form keeps its original expiry and restores the progressed native form" do
    sheet = druid(level: 3)
    before = transformed(sheet)
    assert before.effect_expiries[sheet.name]["wild_shape"] == 3600
    assert {:ok, before} = World.advance_time(1800).(before)
    assert {:ok, native} = Heroes.apply_level_up(sheet, %{})
    assert {:ok, progressed} = World.level_up(sheet.name).(before)
    merged = Games.merge_character_level_up(before, sheet.name, native)

    for w <- [progressed, merged] do
      assert w.effect_expiries == before.effect_expiries
      assert live(w).level == 4
      assert {:ok, almost} = World.advance_time(1799).(roundtrip(w))
      assert live(almost).wild_shape != nil
      assert {:ok, expired} = World.advance_time(1).(almost)
      assert live(expired).wild_shape == nil
      assert live(expired).hp == 7 and live(expired).max_hp == 29
      assert live(expired).con == 18 and live(expired).wild_shape_uses == 1
    end
  end
end
