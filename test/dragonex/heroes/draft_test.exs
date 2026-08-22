defmodule Dragonex.Heroes.DraftTest do
  @moduledoc """
  Deterministic coverage for `Dragonex.Heroes.Draft` — the pure form ↔ draft
  mapping extracted from the hero creator LiveView (D31). Offline by design
  (D9): no Repo, catalog lookups only.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Heroes.Draft

  describe "initial_form/0 · draft_from_form/1 round-trip" do
    test "draft_from_form of the initial form yields string keys with defaults" do
      draft = Draft.initial_form() |> Draft.draft_from_form()

      assert draft["name"] == ""
      assert draft["race"] == nil
      assert draft["score_method"] == "auto"

      assert draft["pb"] == %{
               "str" => 8,
               "dex" => 8,
               "con" => 8,
               "int" => 8,
               "wis" => 8,
               "cha" => 8
             }

      assert draft["skills_choice"] == []
      assert draft["extra_equipment"] == %{"weapons" => [], "items" => []}
    end

    test "a string-keyed draft rehydrates the form via form_from_hero/2" do
      draft =
        Draft.initial_form()
        |> Draft.draft_from_form()
        |> Map.merge(%{
          "name" => "Lyra",
          "race" => "elf",
          "class" => "wizard",
          "background" => "sage",
          "extra_equipment" => %{
            "weapons" => ["custom_w1"],
            "items" => [%{"key" => "custom_i1", "qty" => 2}, "custom_i2"]
          }
        })

      form = Draft.form_from_hero(%{draft: draft}, nil)

      assert form.name == "Lyra"
      assert form.race == "elf"
      assert form.class == "wizard"
      assert form.background == "sage"
      # atom-keyed normalized equipment survives the round trip
      assert form.extra_equipment.weapons == ["custom_w1"]

      assert form.extra_equipment.items == [
               %{key: "custom_i1", qty: 2},
               %{key: "custom_i2", qty: 1}
             ]

      # and serializes back to strings
      assert Draft.draft_from_form(form)["extra_equipment"]["items"] == [
               %{"key" => "custom_i1", "qty" => 2},
               %{"key" => "custom_i2", "qty" => 1}
             ]
    end

    test "a legacy sheet (no draft) maps race/class/sex into the form" do
      sheet = %Dragonex.Character{
        name: "Thane",
        race: "human",
        class: "fighter",
        sex: "hombre",
        background_feature: nil,
        languages: ["common"],
        skill_proficiencies: [],
        spells: []
      }

      form = Draft.form_from_hero(%{draft: nil}, sheet)

      assert form.name == "Thane"
      assert form.race == "human"
      assert form.class == "fighter"
      assert form.sex == "hombre"
      # no draft → spells come from the sheet's own list (empty here)
      assert form.spells == []
    end
  end

  describe "toggle_key/2 · toggle_item/2" do
    test "toggle_key adds then removes" do
      assert Draft.toggle_key([], "custom_w1") == ["custom_w1"]
      assert Draft.toggle_key(["custom_w1"], "custom_w1") == []
    end

    test "toggle_item adds %{key, qty: 1} and removes by key" do
      assert Draft.toggle_item([], "custom_i1") == [%{key: "custom_i1", qty: 1}]
      assert Draft.toggle_item([%{key: "custom_i1", qty: 3}], "custom_i1") == []
    end
  end

  describe "spell bookkeeping" do
    test "spell_level: custom_* consults the injected bundle; unknown → nil" do
      custom = %{spells: [%{key: "custom_s1", definition: %{"level" => 1}}]}
      assert Draft.spell_level("custom_s1", custom) == 1
      assert Draft.spell_level("custom_nope", custom) == nil
      assert Draft.spell_level("custom_s1", %{}) == nil
    end

    test "spell_selected? falls back to class defaults when spells == nil" do
      assert Draft.spell_selected?(%{spells: nil, class: "wizard"}, "firebolt") ==
               "firebolt" in Dragonex.Heroes.Classes.default_spell_names("wizard")
    end

    test "cap_reached? is false when the spell is unknown" do
      refute Draft.cap_reached?("wizard", [], "custom_unknown", %{})
    end
  end

  describe "to_existing_atom/1" do
    test "passes through atoms and existing atom strings" do
      assert Draft.to_existing_atom(:str) == :str
      assert Draft.to_existing_atom("str") == :str
    end

    test "returns unknown binaries unchanged instead of creating atoms (D8)" do
      unknown = "no_such_atom_ever_xyz_#{System.unique_integer()}"
      assert Draft.to_existing_atom(unknown) == unknown
    end
  end
end
