defmodule Dragonex.ConditionsAuditTest do
  @moduledoc """
  Frente 4 (condiciones y duración). Dos casos están en rojo a propósito
  hasta el fix: Esquiva asombrosa no debe morir al empezar el turno (D64),
  y una carga legacy no debe borrar Escudo de la fe al sembrar el reloj.

  No representados, a propósito (D61/D62/D57, sin implementar): distancia,
  alcance, cobertura, línea de visión y ataques de oportunidad. El aura de
  paladín es por `side`, no por pies.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Character, Codec, Rules.Effects, World}

  test "el inicio de turno apaga reckless y smite, no Esquiva asombrosa" do
    hero =
      Character.new(
        name: "Vex",
        class: "rogue",
        level: 5,
        hp: 12,
        max_hp: 12,
        reckless: true,
        smite_slot: 1,
        uncanny_dodge: true
      )

    {:ok, w} = World.begin_combat(["Vex"]).(world([hero]))
    {:ok, w} = World.set_current_combatant("Vex").(w)

    assert w.characters["Vex"].reckless == false
    assert w.characters["Vex"].smite_slot == nil
    assert w.characters["Vex"].uncanny_dodge == true
  end

  test "una reacción no apaga reckless, smite ni Esquiva asombrosa" do
    hero =
      Character.new(
        name: "Vex",
        hp: 12,
        max_hp: 12,
        reckless: true,
        smite_slot: 2,
        uncanny_dodge: true
      )

    {:ok, w} = World.begin_combat(["Vex"]).(world([hero]))
    {:ok, w} = World.set_current_combatant("Vex", "reaction").(w)

    assert w.characters["Vex"].reckless == true
    assert w.characters["Vex"].smite_slot == 2
    assert w.characters["Vex"].uncanny_dodge == true
  end

  test "reseleccionar el mismo turno no vuelve a apagar una postura recién armada" do
    hero = Character.new(name: "Grok", class: "barbarian", level: 2, hp: 20, max_hp: 20)
    {:ok, w} = World.begin_combat(["Grok"]).(world([hero]))
    {:ok, w} = World.set_current_combatant("Grok").(w)
    {:ok, w} = World.set_reckless("Grok", true).(w)
    {:ok, w} = World.set_current_combatant("Grok").(w)

    assert w.characters["Grok"].reckless == true
  end

  test "el turno de otro no apaga el smite pendiente" do
    paladin =
      Character.new(name: "Rhogar", class: "paladin", level: 2, hp: 20, max_hp: 20, smite_slot: 1)

    goblin = Character.new(name: "goblin", side: "enemy", hp: 7, max_hp: 7)
    {:ok, w} = World.begin_combat(["goblin", "Rhogar"]).(world([paladin, goblin]))
    {:ok, w} = World.set_current_combatant("goblin").(w)

    assert w.characters["Rhogar"].smite_slot == 1
  end

  test "fin de combate apaga furia, reckless y smite, no la concentración ni Esquiva asombrosa" do
    hero =
      Character.new(
        name: "Grok",
        hp: 20,
        max_hp: 20,
        raging: true,
        reckless: true,
        smite_slot: 1,
        uncanny_dodge: true,
        concentrating: "bless"
      )

    {:ok, w} = World.begin_combat(["Grok"]).(world([hero]))
    {:ok, w} = World.end_combat().(w)
    c = w.characters["Grok"]

    assert c.raging == false
    assert c.reckless == false
    assert c.smite_slot == nil
    assert c.uncanny_dodge == true
    assert c.concentrating == "bless"
  end

  test "Aura de Coraje no aplica frightened y no deja plazo" do
    paladin =
      Character.new(name: "P", class: "paladin", level: 10, side: "pc", hp: 20, max_hp: 20)

    ally = Character.new(name: "A", side: "pc", hp: 10, max_hp: 10)
    w = world([paladin, ally])

    {:ok, w} = World.apply_condition("A", "frightened", 60).(w)

    refute World.has_condition?(w, "A", "frightened")
    refute Map.has_key?(w.effect_expiries["A"] || %{}, "condition:frightened")
    assert w.characters["A"].conditions == []
  end

  test "la inmunidad no bloquea otras condiciones ni se aplica dos veces" do
    paladin =
      Character.new(name: "P", class: "paladin", level: 10, side: "pc", hp: 20, max_hp: 20)

    ally = Character.new(name: "A", side: "pc", hp: 10, max_hp: 10)
    w = world([paladin, ally])

    {:ok, w} = World.apply_condition("A", "prone").(w)
    {:ok, w} = World.apply_condition("A", "prone").(w)
    {:ok, w} = World.apply_condition("P", "frightened").(w)

    assert World.has_condition?(w, "A", "prone")

    assert Enum.count(w.characters["A"].conditions, &(Character.condition_name(&1) == "prone")) ==
             1

    refute World.has_condition?(w, "P", "frightened")
  end

  test "un paladín caído no concede la inmunidad" do
    paladin = Character.new(name: "P", class: "paladin", level: 10, side: "pc", hp: 0, max_hp: 20)
    ally = Character.new(name: "A", side: "pc", hp: 10, max_hp: 10)
    {:ok, w} = World.apply_condition("A", "frightened").(world([paladin, ally]))

    assert World.has_condition?(w, "A", "frightened")
  end

  test "soltar concentración limpia Bless y devuelve la CA de Escudo de la fe" do
    w = linked_world()
    assert Effects.effective_ac(w.characters["A"]) == 20
    assert w.characters["A"].ac == 18
    assert Effects.blessed?(w.characters["B"])

    {:ok, w} = World.clear_concentration("C").(w)
    {:ok, w} = World.clear_concentration("D").(w)

    assert w.characters["C"].concentrating == nil
    refute Effects.shielded_by_faith?(w.characters["A"])
    refute Effects.blessed?(w.characters["B"])
    assert Effects.effective_ac(w.characters["A"]) == 18
  end

  test "caer a 0, entrar en furia o quedar incapacitado limpian los efectos de la fuente" do
    for setup <- [:drop, :rage, :incap] do
      w = faith_world()

      {:ok, w} =
        case setup do
          :drop -> World.apply_damage("C", 50).(w)
          :rage -> World.set_raging("C", true).(w)
          :incap -> World.apply_condition("C", "incapacitated").(w)
        end

      assert w.characters["C"].concentrating == nil, "#{setup}"
      assert Effects.effective_ac(w.characters["A"]) == 18, "#{setup}"
    end
  end

  test "la marca del cazador vive en concentrating y desaparece al soltarla" do
    hunter =
      Character.new(
        name: "R",
        class: "ranger",
        level: 2,
        hp: 12,
        max_hp: 12,
        concentrating: "hunter's mark:goblin"
      )

    {:ok, w} = World.clear_concentration("R").(world([hunter]))

    assert w.characters["R"].concentrating == nil
  end

  test "caducar la concentración devuelve la CA base y no deja el efecto huérfano" do
    w = faith_world()
    {:ok, w} = World.advance_time(600).(w)

    assert w.characters["C"].concentrating == nil
    assert Effects.effective_ac(w.characters["A"]) == 18
  end

  test "una condición sin plazo no caduca; una con plazo caduca al vencer y no antes" do
    hero = Character.new(name: "A", hp: 10, max_hp: 10)
    {:ok, w} = World.apply_condition("A", "prone").(world([hero]))
    {:ok, w} = World.apply_condition("A", "frightened", 60).(w)

    {:ok, early} = World.advance_time(59).(w)
    assert World.has_condition?(early, "A", "prone")
    assert World.has_condition?(early, "A", "frightened")

    {:ok, due} = World.advance_time(60).(w)
    assert World.has_condition?(due, "A", "prone")
    refute World.has_condition?(due, "A", "frightened")
    refute Map.has_key?(due.effect_expiries["A"] || %{}, "condition:frightened")
  end

  test "oculto no recibe plazo y no caduca con el reloj" do
    hero = Character.new(name: "Vex", class: "rogue", level: 2, hp: 10, max_hp: 10)
    {:ok, w} = World.apply_condition("Vex", "hidden").(world([hero]))
    {:ok, w} = World.advance_time(3600).(w)

    assert World.has_condition?(w, "Vex", "hidden")
    assert w.effect_expiries["Vex"] == nil or w.effect_expiries["Vex"] == %{}
  end

  test "cargar un mundo legacy conserva Escudo de la fe y siembra el plazo" do
    raw = faith_world() |> Codec.encode() |> Map.delete("effect_expiries")
    loaded = Codec.decode(raw)

    assert loaded.characters["C"].concentrating == "shield of faith"
    assert Effects.effective_ac(loaded.characters["A"]) == 20
    assert loaded.effect_expiries["C"]["concentrating"] == 600
  end

  defp world(chars), do: World.new(characters: Map.new(chars, &{&1.name, &1}))

  defp faith_world do
    caster = Character.new(name: "C", class: "cleric", level: 1, hp: 12, max_hp: 12, ac: 12)
    ally = Character.new(name: "A", hp: 12, max_hp: 12, ac: 18)
    {:ok, w} = World.shield_of_faith("C", ["A"]).(world([caster, ally]))
    w
  end

  defp linked_world do
    shielded = faith_world()
    cleric = Character.new(name: "D", class: "cleric", level: 1, hp: 12, max_hp: 12)
    target = Character.new(name: "B", hp: 12, max_hp: 12)
    w = %{shielded | characters: Map.merge(shielded.characters, %{"D" => cleric, "B" => target})}
    {:ok, w} = World.bless("D", ["B"], 1).(w)
    w
  end
end
