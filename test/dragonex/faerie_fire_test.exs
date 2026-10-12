defmodule Dragonex.FaerieFireTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Weapon, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Conditions

  defp seq(values) do
    Process.put(:fire_rolls, values)

    fn sides ->
      [value | rest] = Process.get(:fire_rolls)
      assert value in 1..sides
      Process.put(:fire_rolls, rest)
      value
    end
  end

  defp spent?, do: Process.get(:fire_rolls, [])
  defp no_roll(_), do: flunk("no debía tirar")

  defp caster do
    spell = Spells.to_character_spell(Spells.get("faerie fire"), :int)

    Character.new(
      name: "Vex",
      class: "wizard",
      level: 3,
      hp: 20,
      max_hp: 20,
      int: 16,
      spells: [spell]
    )
  end

  defp target(opts) do
    Character.new(
      Keyword.merge(
        [name: "Ada", race: "human", hp: 12, max_hp: 12, dex: 14, ac: 12, side: "enemy"],
        opts
      )
    )
  end

  defp world(extra) do
    World.new(
      characters: Map.new([caster() | extra], &{&1.name, &1}),
      spell_slots: %{"Vex" => %{1 => 4, 2 => 2}}
    )
  end

  defp marked?(w, name) do
    "faerie_fire" in Character.condition_names(w.characters[name])
  end

  defp cast!(w, roller) do
    assert {:ok, msg, change} = Actions.spell(w, "Vex", "faerie fire", "Ada", roller, nil)
    assert {:ok, next} = change.(w)
    {msg, next}
  end

  test "fallo de Destreza marca, concentra 1 minuto y no lo da un éxito" do
    w = world([target(dex: 10)])
    {fail, marked} = cast!(w, seq([8]))
    assert fail =~ "falla la salvación de Destreza"
    assert fail =~ "8 vs CD 13"
    assert fail =~ "concentra en Fuego de hadas"
    assert marked?(marked, "Ada")
    assert marked.characters["Vex"].concentrating == "faerie fire"
    assert marked.effect_expiries["Vex"]["concentrating"] == 60
    assert marked.spell_slots["Vex"][1] == 3
    assert spent?() == []

    w = world([target(dex: 10)])
    {ok, clean} = cast!(w, seq([15]))
    assert ok =~ "supera la salvación de Destreza"
    assert ok =~ "15 vs CD 13"
    refute ok =~ "concentra"
    refute marked?(clean, "Ada")
    assert clean.characters["Vex"].concentrating == nil
    assert spent?() == []
  end

  test "la marca da ventaja a cualquier atacante y se cancela con su desventaja" do
    {_msg, w} = cast!(world([target(dex: 10, ac: 10)]), seq([8]))
    ada = w.characters["Ada"]
    attacker = Character.new(name: "Thane", hp: 20, max_hp: 20, str: 16)

    assert Conditions.attack_mode(attacker, ada) == :advantage
    assert Conditions.attack_mode(attacker, ada, requested: :disadvantage) == :normal

    sword = %Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
    thane = %{attacker | weapons: [sword]}
    w = %{w | characters: Map.put(w.characters, "Thane", thane)}

    assert {:ok, msg, _} = Actions.attack(w, "Thane", "Ada", "longsword", seq([18, 3, 4]))
    assert msg =~ "(ventaja)"
    assert spent?() == []

    assert {:ok, plain, _} =
             Actions.attack(w, "Thane", "Ada", "longsword", seq([12, 4]), :disadvantage)

    refute plain =~ "(ventaja)"
    refute plain =~ "(desventaja)"
    assert spent?() == []
  end

  test "Twinned marca solo al que falla" do
    other = target(name: "Bea", dex: 10)
    w = world([target(dex: 10), other])
    {:ok, w} = World.set_metamagic("Vex", %{option: "twinned", target: "Bea"}).(w)

    assert {:ok, msg, change} = Actions.spell(w, "Vex", "faerie fire", "Ada", seq([8, 15]), nil)
    assert {:ok, next} = change.(w)
    assert msg =~ "Twinned"
    assert marked?(next, "Ada")
    refute marked?(next, "Bea")
    assert next.characters["Vex"].concentrating == "faerie fire"
    assert next.characters["Vex"].metamagic == nil
    assert spent?() == []
  end

  test "romper la concentración quita la marca en todas las rutas" do
    for route <- [:drop, :zero, :rage, :incap, :clock] do
      {_msg, w} = cast!(world([target(dex: 10)]), seq([8]))
      assert marked?(w, "Ada")

      {:ok, w} =
        case route do
          :drop -> World.clear_concentration("Vex").(w)
          :zero -> World.apply_damage("Vex", 50).(w)
          :rage -> World.set_raging("Vex", true).(w)
          :incap -> World.apply_condition("Vex", "incapacitated").(w)
          :clock -> World.advance_time(60).(w)
        end

      refute marked?(w, "Ada"), "#{route}"
      assert w.characters["Vex"].concentrating == nil, "#{route}"
    end
  end

  test "la aura D61 suma a la salvación de Destreza" do
    paladin =
      Character.new(
        name: "P",
        class: "paladin",
        level: 6,
        side: "pc",
        hp: 20,
        max_hp: 20,
        cha: 16
      )

    ada = target(side: "pc", dex: 10)
    w = world([ada, paladin])
    {msg, next} = cast!(w, seq([10]))
    assert msg =~ "13 vs CD 13"
    assert msg =~ "+3 aura"
    refute marked?(next, "Ada")
    assert spent?() == []
  end

  test "Codec conserva la marca y un objetivo muerto no muta" do
    {_msg, w} = cast!(world([target(dex: 10)]), seq([8]))
    again = Codec.decode(Codec.encode(w))
    entry = Enum.find(again.characters["Ada"].conditions, &(&1["condition"] == "faerie_fire"))
    assert entry["source"] == "faerie_fire:Vex"
    assert again.characters["Vex"].concentrating == "faerie fire"

    dead = target(death_saves: %{successes: 0, fails: 3})
    w = world([dead])
    assert {:error, msg} = Actions.spell(w, "Vex", "faerie fire", "Ada", &no_roll/1, nil)
    assert msg =~ "muerto"
    assert w.spell_slots["Vex"][1] == 4
  end
end
