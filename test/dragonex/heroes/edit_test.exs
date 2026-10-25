defmodule Dragonex.Heroes.EditTest do
  use ExUnit.Case, async: true

  alias Dragonex.{ClassResources, Codec, Heroes, World}
  alias Dragonex.Heroes.{Draft, Edit}

  for class <- ["fighter", "wizard", "monk"] do
    test "identity changes preserve the complete progressed #{class} sheet" do
      {hero, form, sheet} = fixture(unquote(class), 5)
      sheet = %{sheet | hp: 0, temp_hp: 4, death_saves: %{successes: 2, fails: 1}, xp: 7_123}
      changed = %{form | name: "Otro nombre", backstory: "Una historia nueva.", sex: "mujer"}

      assert {:ok, edited} = rebuild(hero, sheet, form, changed)

      assert edited == %{
               sheet
               | name: "Otro nombre",
                 backstory: "Una historia nueva.",
                 sex: "mujer"
             }

      assert {:ok, ^sheet} = rebuild(hero, sheet, form, form)
    end
  end

  test "equipment changes preserve earned ASI, HP, XP and used features without repeated gains" do
    {hero, form, sheet} = fixture("fighter", 5, asi: %{con: 2})
    sheet = %{sheet | hp: 7, second_wind_used: true, action_surge_used: true, xp: 8_200}
    changed = %{form | equipment: %{armor: 1}}
    assert {:ok, edited} = rebuild(hero, sheet, form, changed)
    assert edited.level == 5
    assert edited.xp == 8_200
    assert edited.con == sheet.con
    assert edited.max_hp == sheet.max_hp
    assert edited.hp == 7
    assert edited.second_wind_used and edited.action_surge_used
    assert edited.class_features == sheet.class_features
    assert edited.ac != sheet.ac
    assert Enum.any?(edited.inventory, &(&1.name == "leather armor"))
    assert {:ok, ^edited} = rebuild(hero, sheet, form, changed)
    assert {:ok, ^sheet} = rebuild(hero, sheet, form, form)
  end

  test "changing CON recalculates maximum HP once but never heals current HP" do
    {hero, form, sheet} = fixture("fighter", 5, asi: %{con: 2})

    changed = %{
      form
      | score_method: "pointbuy",
        pb: %{str: 15, dex: 13, con: 12, int: 8, wis: 12, cha: 10}
    }

    assert {:ok, edited} = rebuild(hero, sheet, form, changed)
    assert edited.con == 15
    assert edited.max_hp == sheet.max_hp - 5
    assert edited.hp == min(sheet.hp, edited.max_hp)
    assert edited.xp == sheet.xp
    assert {:ok, ^edited} = rebuild(hero, sheet, form, changed)
  end

  test "an unrelated legacy language change does not normalize confirmed stats, AC or maximum HP" do
    {hero, _form, sheet} = fixture("fighter", 5)
    sheet = %{sheet | str: 19, max_hp: 50, hp: 47, ac: 23}
    hero = %{hero | sheet: Codec.encode_character(sheet), draft: nil}
    form = Draft.form_from_hero(hero, sheet)
    changed = %{form | extra_langs: ["elvish"]}
    assert {:ok, edited} = rebuild(hero, sheet, form, changed)

    assert Map.take(edited, [:str, :dex, :con, :int, :wis, :cha, :hp, :max_hp, :ac, :level, :xp]) ==
             Map.take(sheet, [:str, :dex, :con, :int, :wis, :cha, :hp, :max_hp, :ac, :level, :xp])

    assert "elvish" in edited.languages

    saved = saved(hero, changed, edited)
    assert Edit.legacy?(saved)
    next_form = Draft.form_from_hero(saved, edited)

    assert {:ok, next} =
             rebuild(saved, edited, next_form, %{next_form | extra_langs: ["dwarvish"]})

    assert next.str == 19
    assert next.max_hp == 50
  end

  test "a class change derives features, armor and resources at the saved level" do
    {hero, form, sheet} = fixture("wizard", 5)
    sheet = %{sheet | hp: 3, xp: 8_222, arcane_recovery_used: true}
    changed = change_class(form, "fighter")
    assert {:ok, edited} = rebuild(hero, sheet, form, changed)
    assert edited.class == "fighter"
    assert edited.level == 5
    assert edited.xp == 8_222
    assert edited.hp == 3
    assert edited.max_hp > sheet.max_hp
    assert "action_surge" in edited.class_features
    assert "extra_attack" in edited.class_features
    refute "spellcasting" in edited.class_features
    assert edited.spells == []
    assert edited.arcane_recovery_used
    assert edited.saving_proficiencies == ["str", "con"]
  end

  test "higher spells survive equipment edits and compatible class changes with the new ability" do
    {hero, form, sheet} = fixture("wizard", 5)
    {:ok, fireball} = resolve_spell("fireball", :int)
    sheet = %{sheet | spells: sheet.spells ++ [fireball], concentrating: "invisibility"}
    assert {:ok, equipped} = rebuild(hero, sheet, form, %{form | equipment: %{weapon: 1}})
    assert equipped.spells == sheet.spells
    assert equipped.concentrating == sheet.concentrating

    assert {:ok, sorcerer} = rebuild(hero, sheet, form, change_class(form, "sorcerer"))
    assert Enum.find(sorcerer.spells, &(&1.name == "fireball")).casting_ability == :cha
    assert sorcerer.sorcery_points == 5
  end

  test "changing base spell choices keeps spells earned after character creation" do
    {hero, form, sheet} = fixture("wizard", 5)
    {:ok, fireball} = resolve_spell("fireball", :int)
    sheet = %{sheet | spells: sheet.spells ++ [fireball]}
    changed = %{form | spells: ["fire bolt", "magic missile"]}
    assert {:ok, edited} = rebuild(hero, sheet, form, changed)
    assert Enum.map(edited.spells, & &1.name) == ["fire bolt", "magic missile", "fireball"]
    assert {:error, _} = rebuild(hero, sheet, form, %{form | spells: ["heal"]})
  end

  test "encoded hunter's mark concentration survives equipment changes" do
    {hero, form, sheet} = fixture("ranger", 5)
    sheet = %{sheet | concentrating: "hunter's mark:goblin"}
    assert {:ok, edited} = rebuild(hero, sheet, form, %{form | equipment: %{armor: 1}})
    assert edited.concentrating == sheet.concentrating
  end

  test "spent pools survive changing away from a class and back across saved drafts" do
    {hero, form, monk} = fixture("monk", 5)
    monk = %{monk | ki: 1}
    hero = %{hero | sheet: Codec.encode_character(monk)}
    fighter_form = change_class(form, "fighter")
    assert {:ok, fighter} = rebuild(hero, monk, form, fighter_form)
    saved = saved(hero, fighter_form, fighter)
    initial = Draft.form_from_hero(saved, fighter)
    assert {:ok, returned} = rebuild(saved, fighter, initial, change_class(initial, "monk"))
    assert returned.ki == 1
    assert returned.hp <= fighter.hp
  end

  test "lowering then restoring a capacity does not refund spent uses" do
    {hero, form, bard} = fixture("bard", 5)
    bard = %{bard | bardic_inspiration_uses: 0}
    hero = %{hero | sheet: Codec.encode_character(bard)}

    low = %{
      form
      | score_method: "pointbuy",
        pb: %{str: 8, dex: 13, con: 14, int: 10, wis: 12, cha: 8}
    }

    assert {:ok, lowered} = rebuild(hero, bard, form, low)
    assert ClassResources.capacities(lowered).bardic_inspiration_uses == 1
    saved = saved(hero, low, lowered)
    initial = Draft.form_from_hero(saved, lowered)
    assert {:ok, raised} = rebuild(saved, lowered, initial, %{initial | score_method: "auto"})
    assert raised.cha == bard.cha
    assert raised.bardic_inspiration_uses == 0
  end

  test "a real resource recharge supersedes the prior edit ledger" do
    {hero, form, monk} = fixture("monk", 5)
    monk = %{monk | ki: 1}
    hero = %{hero | sheet: Codec.encode_character(monk)}
    saved = saved(hero, form, monk)
    assert Edit.spending(saved).ki == 4
    world = World.new(characters: %{monk.name => monk})

    assert {:ok, _message, rest} =
             Dragonex.Actions.short_rest(
               world,
               monk.name,
               fn _ -> flunk("no hit dice spent") end,
               nil,
               0
             )

    assert {:ok, rested} = rest.(world)
    rested = rested.characters[monk.name]
    assert rested.ki == 5
    saved = %{saved | sheet: Codec.encode_character(rested)}
    initial = Draft.form_from_hero(saved, rested)
    assert Edit.spending(saved).ki == 0
    assert {:ok, edited} = rebuild(saved, rested, initial, %{initial | extra_langs: ["elvish"]})
    assert edited.ki == 5
  end

  defp fixture(class, level, opts \\ []) do
    form = %{
      Draft.initial_form()
      | name: "Hero",
        race: "human",
        class: class,
        background: "soldier"
    }

    {:ok, base} =
      Heroes.build(%{name: form.name, race: form.race, class: class, background: form.background})

    sheet =
      if level == 1 do
        base
      else
        Enum.reduce(2..level, base, fn next_level, sheet ->
          choices = if next_level == 4, do: %{asi: Keyword.get(opts, :asi, %{})}, else: %{}
          {:ok, leveled} = Heroes.apply_level_up(sheet, choices)
          leveled
        end)
      end

    {%{sheet: Codec.encode_character(sheet), draft: Draft.draft_from_form(form)}, form, sheet}
  end

  defp rebuild(hero, original, initial, form),
    do:
      Edit.rebuild(original, initial, form,
        legacy: Edit.legacy?(hero),
        spent: Edit.spending(hero)
      )

  defp saved(hero, form, sheet),
    do: %{hero | sheet: Codec.encode_character(sheet), draft: Edit.draft(form, hero, sheet)}

  defp change_class(form, class),
    do: %{form | class: class, equipment: %{}, spells: nil, skills_choice: []}

  defp resolve_spell(name, ability),
    do:
      {:ok,
       name |> Dragonex.Heroes.Spells.get() |> Dragonex.Heroes.Spells.to_character_spell(ability)}
end
