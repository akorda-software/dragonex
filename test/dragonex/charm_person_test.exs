defmodule Dragonex.CharmPersonTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Weapon, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Conditions

  defp seq(values) do
    Process.put(:charm_rolls, values)

    fn sides ->
      [value | rest] = Process.get(:charm_rolls)
      assert value in 1..sides
      Process.put(:charm_rolls, rest)
      value
    end
  end

  defp spent?, do: Process.get(:charm_rolls, [])
  defp no_roll(_), do: flunk("no debía tirar")

  defp caster do
    spell = Spells.to_character_spell(Spells.get("charm person"), :int)

    Character.new(
      name: "Vex",
      class: "wizard",
      level: 1,
      hp: 20,
      max_hp: 20,
      int: 16,
      side: "pc",
      spells: [spell]
    )
  end

  defp human(name, opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: name, race: "human", hp: 12, max_hp: 12, wis: 10, ac: 10, side: "enemy"],
        opts
      )
    )
  end

  defp world(extra, phase \\ :exploration) do
    World.new(
      characters: Map.new([caster() | extra], &{&1.name, &1}),
      spell_slots: %{"Vex" => %{1 => 2}},
      phase: phase
    )
  end

  defp cast!(w, target, roller) do
    assert {:ok, msg, change} = Actions.spell(w, "Vex", "charm person", target, roller, nil)
    assert {:ok, next} = change.(w)
    {msg, next}
  end

  defp charmed?(w, name) do
    "charmed" in Character.condition_names(w.characters[name])
  end

  test "fuera de combate un d20; fallo encanta 1 hora sin concentrar" do
    {msg, w} = cast!(world([human("Ada")]), "Ada", seq([8]))
    assert msg =~ "falla la salvación de Sabiduría"
    assert msg =~ "8 vs CD 13"
    refute msg =~ "concentra"
    assert charmed?(w, "Ada")
    assert w.characters["Vex"].concentrating == nil
    assert w.effect_expiries["Ada"]["condition:charmed"] == 3600
    assert w.spell_slots["Vex"][1] == 1
    assert w.characters["Ada"].side == "enemy"
    assert spent?() == []
  end

  test "en combate la salvación tiene ventaja y no se apila con la gnoma" do
    {msg, w} = cast!(world([human("Ada")], :combat), "Ada", seq([4, 16]))
    assert msg =~ "supera la salvación de Sabiduría"
    assert msg =~ "16 vs CD 13"
    refute charmed?(w, "Ada")
    assert spent?() == []

    gnome = human("Nim", race: "gnome")
    {msg, w} = cast!(world([gnome]), "Nim", seq([3, 9]))
    assert msg =~ "falla la salvación de Sabiduría"
    assert msg =~ "9 vs CD 13"
    assert charmed?(w, "Nim")
    assert spent?() == []
  end

  test "desventaja solo al atacar al lanzador" do
    {_msg, w} = cast!(world([human("Ada")]), "Ada", seq([8]))
    sword = %Weapon{name: "dagger", dice: "1d4", damage_type: "piercing", attack_ability: :dex}
    ada = %{w.characters["Ada"] | weapons: [sword], dex: 14}
    other = human("Bea", side: "pc")
    w = %{w | characters: Map.merge(w.characters, %{"Ada" => ada, "Bea" => other})}

    assert Conditions.attack_mode(ada, w.characters["Vex"]) == :disadvantage
    assert Conditions.attack_mode(ada, other) == :normal

    assert {:ok, msg, _} = Actions.attack(w, "Ada", "Vex", "dagger", seq([18, 12, 2]))
    assert msg =~ "(desventaja)"
    assert spent?() == []

    assert {:ok, plain, _} = Actions.attack(w, "Ada", "Bea", "dagger", seq([15, 2]))
    refute plain =~ "(desventaja)"
    assert spent?() == []
  end

  test "el daño del lanzador o de su side rompe el encanto; el de un tercero no" do
    {_msg, w} = cast!(world([human("Ada")]), "Ada", seq([8]))

    {:ok, intact} =
      World.apply_damage("Ada", 2, "slashing", fn _ -> 1 end,
        attacker: "Ogro",
        attacker_side: "enemy"
      ).(w)

    assert charmed?(intact, "Ada")

    {:ok, broken} =
      World.apply_damage("Ada", 2, "slashing", fn _ -> 1 end,
        attacker: "Vex",
        attacker_side: "pc"
      ).(w)

    refute charmed?(broken, "Ada")
    assert broken.effect_expiries["Ada"]["condition:charmed"] == nil

    {_msg, w} = cast!(world([human("Ada")]), "Ada", seq([8]))

    {:ok, ally} =
      World.apply_damage("Ada", 1, nil, fn _ -> 1 end, attacker: "Thane", attacker_side: "pc").(w)

    refute charmed?(ally, "Ada")
  end

  test "el plazo de 1 hora lo quita; un beast no muta; Codec conserva la fuente" do
    {_msg, w} = cast!(world([human("Ada")]), "Ada", seq([8]))
    {:ok, w} = World.advance_time(3600).(w)
    refute charmed?(w, "Ada")

    beast = human("Lobo", race: "beast")
    w = world([beast])
    assert {:error, msg} = Actions.spell(w, "Vex", "charm person", "Lobo", &no_roll/1, nil)
    assert msg =~ "humanoides"
    assert w.spell_slots["Vex"][1] == 2

    {_msg, w} = cast!(world([human("Ada")]), "Ada", seq([8]))
    again = Codec.decode(Codec.encode(w))
    entry = Enum.find(again.characters["Ada"].conditions, &(&1["condition"] == "charmed"))
    assert entry["source"] == "charm_person:Vex"
    assert entry["caster_side"] == "pc"
  end
end
