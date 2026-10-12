defmodule Dragonex.ActionIncapacitationTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, World}

  defp no_roll(_), do: flunk("incapacitated actors must not roll")

  test "active abilities reject every incapacitating condition before rolling or spending" do
    calls = [
      fn w -> Actions.attack(w, "Hero", "Hero", "longsword", &no_roll/1) end,
      fn w -> Actions.spell(w, "Hero", "cure wounds", "Hero", &no_roll/1) end,
      fn w -> Actions.second_wind(w, "Hero", &no_roll/1) end,
      fn w -> Actions.lay_on_hands(w, "Hero", "Hero", 1) end,
      fn w -> Actions.divine_sense(w, "Hero") end,
      fn w -> Actions.turn_undead(w, "Hero", &no_roll/1) end,
      fn w -> Actions.bardic_inspiration(w, "Hero", "Hero") end,
      fn w -> Actions.wild_shape(w, "Hero", "wolf") end,
      fn w -> Actions.end_wild_shape(w, "Hero") end,
      fn w -> Actions.action_surge(w, "Hero", "Hero", "longsword", &no_roll/1) end,
      fn w -> Actions.flurry_of_blows(w, "Hero", "Hero", &no_roll/1) end,
      fn w -> Actions.hunters_mark(w, "Hero", "Hero", &no_roll/1) end,
      fn w -> Actions.cunning_action_hide(w, "Hero", &no_roll/1) end,
      fn w -> Actions.start_uncanny_dodge(w, "Hero") end,
      fn w -> Actions.create_spell_slot(w, "Hero", 1) end,
      fn w -> Actions.convert_to_sorcery_points(w, "Hero", 1) end,
      fn w -> Actions.arm_metamagic(w, "Hero", "empowered") end,
      fn w -> Actions.breath_weapon(w, "Hero", "Hero", &no_roll/1) end
    ]

    for condition <- ~w(incapacitated stunned paralyzed petrified unconscious),
        {call, index} <- Enum.with_index(calls) do
      c = Character.new(name: "Hero", hp: 5, max_hp: 12, conditions: [condition])
      w = World.new(characters: %{"Hero" => c})
      assert {:error, message} = call.(w)
      assert message =~ "incapacitado", "action #{index}, condition #{condition}: #{message}"
    end
  end

  test "a downed fighter cannot heal itself with Second Wind" do
    c = Character.new(name: "Hero", class: "fighter", hp: 0, max_hp: 12)
    w = World.new(characters: %{"Hero" => c})
    assert {:error, _} = Actions.second_wind(w, "Hero", &no_roll/1)
    assert {:error, _} = World.second_wind("Hero", 5).(w)
  end

  test "direct World entry points also reject incapacitated actors" do
    for condition <- ~w(incapacitated stunned paralyzed petrified unconscious),
        {class, change} <- [
          {"fighter", World.second_wind("Hero", 5)},
          {"paladin", World.lay_on_hands("Hero", "Hero", 5)},
          {"paladin", World.start_smite("Hero", 1)},
          {"barbarian", World.start_rage("Hero")},
          {"barbarian", World.start_reckless("Hero")}
        ] do
      c =
        Character.new(
          name: "Hero",
          class: class,
          level: 5,
          hp: 5,
          max_hp: 12,
          lay_on_hands_pool: 5,
          conditions: [condition]
        )

      w = World.new(characters: %{"Hero" => c})
      assert {:error, message} = change.(w)
      assert message =~ "incapacitado"
    end
  end

  test "a downed paladin cannot heal itself with Lay on Hands" do
    c = Character.new(name: "Hero", class: "paladin", hp: 0, max_hp: 12, lay_on_hands_pool: 5)
    w = World.new(characters: %{"Hero" => c})
    assert {:error, _} = Actions.lay_on_hands(w, "Hero", "Hero", 5)
    assert {:error, _} = World.lay_on_hands("Hero", "Hero", 5).(w)
  end

  test "a prepared action is rejected if its actor becomes incapacitated before application" do
    c = Character.new(name: "Hero", class: "fighter", hp: 5, max_hp: 12)
    w = World.new(characters: %{"Hero" => c})
    {:ok, _, change} = Actions.second_wind(w, "Hero", fn _ -> 1 end)
    c = %{c | conditions: ["stunned"]}
    assert {:error, _} = change.(%{w | characters: %{"Hero" => c}})
  end
end
