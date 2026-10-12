defmodule Dragonex.MageArmorTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Item, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Effects

  defp no_roll(_), do: flunk("no debía tirar")

  defp caster do
    spell = Spells.to_character_spell(Spells.get("mage armor"), :int)

    Character.new(
      name: "Vex",
      class: "wizard",
      level: 1,
      hp: 20,
      max_hp: 20,
      int: 16,
      ac: 11,
      dex: 14,
      spells: [spell]
    )
  end

  defp world(extra) do
    World.new(
      characters: Map.new([caster() | extra], &{&1.name, &1}),
      spell_slots: %{"Vex" => %{1 => 2}}
    )
  end

  defp cast!(w, target) do
    assert {:ok, msg, change} = Actions.spell(w, "Vex", "mage armor", target, &no_roll/1, nil)
    assert {:ok, next} = change.(w)
    {msg, next}
  end

  test "13+DES si supera la CA, no muta la ficha y no concentra" do
    agile = Character.new(name: "Ada", hp: 10, max_hp: 10, ac: 11, dex: 18)
    {_msg, w} = cast!(world([agile]), "Ada")

    assert Effects.effective_ac(w.characters["Ada"]) == 17
    assert w.characters["Ada"].ac == 11
    assert w.characters["Vex"].concentrating == nil
    assert w.effect_expiries["Ada"]["condition:mage_armor"] == 28_800
    assert w.spell_slots["Vex"][1] == 1
  end

  test "DES baja no empeora la CA; armadura anula la fórmula y el escudo no" do
    clumsy = Character.new(name: "Ada", hp: 10, max_hp: 10, ac: 10, dex: 8)
    {_msg, w} = cast!(world([clumsy]), "Ada")
    assert Effects.effective_ac(w.characters["Ada"]) == 12

    armored =
      Character.new(
        name: "Bea",
        hp: 10,
        max_hp: 10,
        ac: 16,
        dex: 18,
        inventory: [%Item{name: "leather armor", qty: 1, kind: :armor}]
      )

    {_msg, w} = cast!(world([armored]), "Bea")
    assert Effects.mage_armored?(w.characters["Bea"])
    assert Effects.effective_ac(w.characters["Bea"]) == 16

    shielded =
      Character.new(
        name: "Cia",
        hp: 10,
        max_hp: 10,
        ac: 11,
        dex: 18,
        inventory: [%Item{name: "shield", qty: 1, kind: :armor}]
      )

    {_msg, w} = cast!(world([shielded]), "Cia")
    assert Effects.effective_ac(w.characters["Cia"]) == 17
  end

  test "el reloj de 8 horas la quita y relanzar renueva el plazo" do
    ada = Character.new(name: "Ada", hp: 10, max_hp: 10, ac: 11, dex: 18)
    {_msg, w} = cast!(world([ada]), "Ada")
    {:ok, w} = World.advance_time(1000).(w)
    {_msg, w} = cast!(w, "Ada")
    assert w.effect_expiries["Ada"]["condition:mage_armor"] == 1000 + 28_800
    assert Effects.effective_ac(w.characters["Ada"]) == 17

    {:ok, w} = World.advance_time(28_799).(w)
    assert Effects.mage_armored?(w.characters["Ada"])
    {:ok, w} = World.advance_time(1).(w)
    refute Effects.mage_armored?(w.characters["Ada"])
    assert Effects.effective_ac(w.characters["Ada"]) == 11
  end

  test "Twinned marca a los dos con una casilla y Codec la conserva" do
    a = Character.new(name: "Ada", hp: 10, max_hp: 10, ac: 11, dex: 16)
    b = Character.new(name: "Bea", hp: 10, max_hp: 10, ac: 11, dex: 16)
    w = world([a, b])
    {:ok, w} = World.set_metamagic("Vex", %{option: "twinned", target: "Bea"}).(w)

    assert {:ok, msg, change} = Actions.spell(w, "Vex", "mage armor", "Ada", &no_roll/1, nil)
    assert {:ok, next} = change.(w)
    assert msg =~ "Twinned"
    assert Effects.effective_ac(next.characters["Ada"]) == 16
    assert Effects.effective_ac(next.characters["Bea"]) == 16
    assert next.spell_slots["Vex"][1] == 1
    assert next.characters["Vex"].metamagic == nil

    again = Codec.decode(Codec.encode(next))
    assert Effects.mage_armored?(again.characters["Ada"])
    assert Effects.effective_ac(again.characters["Ada"]) == 16
  end
end
