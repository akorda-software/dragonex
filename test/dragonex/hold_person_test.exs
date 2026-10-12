defmodule Dragonex.HoldPersonTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Weapon, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Conditions

  defp seq(values) do
    Process.put(:hold_rolls, values)

    fn sides ->
      [value | rest] = Process.get(:hold_rolls)
      assert value in 1..sides
      Process.put(:hold_rolls, rest)
      value
    end
  end

  defp spent?, do: Process.get(:hold_rolls, [])
  defp no_roll(_), do: flunk("no debía tirar")

  defp caster do
    spell = Spells.to_character_spell(Spells.get("hold person"), :int)

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

  defp humanoid(name, opts \\ []) do
    Character.new(
      Keyword.merge([name: name, race: "human", hp: 12, max_hp: 12, wis: 10, ac: 12], opts)
    )
  end

  defp world(extra) do
    chars = [caster() | extra]

    World.new(
      characters: Map.new(chars, &{&1.name, &1}),
      spell_slots: %{"Vex" => %{1 => 4, 2 => 2}}
    )
  end

  defp cast!(w, target, roller) do
    assert {:ok, msg, change} = Actions.spell(w, "Vex", "hold person", target, roller, nil)
    assert {:ok, next} = change.(w)
    {msg, next}
  end

  defp paralyzed?(w, name) do
    "paralyzed" in Character.condition_names(w.characters[name])
  end

  test "fallo de Sabiduría paraliza, concentra 1 minuto y gasta la casilla" do
    target = humanoid("Ada", wis: 8)
    w = world([target])
    {msg, next} = cast!(w, "Ada", seq([10]))

    assert msg =~ "falla la salvación de Sabiduría"
    assert msg =~ "9 vs CD 13"
    assert msg =~ "concentra en Inmovilizar persona"
    assert paralyzed?(next, "Ada")
    assert next.characters["Vex"].concentrating == "hold person"
    assert next.effect_expiries["Vex"]["concentrating"] == 60
    assert next.spell_slots["Vex"][2] == 1
    entry = Enum.find(next.characters["Ada"].conditions, &(&1["source"] == "hold_person:Vex"))
    assert entry["dc"] == 13
    assert spent?() == []
  end

  test "superar la salvación no paraliza ni concentra, pero gasta la casilla" do
    w = world([humanoid("Ada", wis: 8)])
    {msg, next} = cast!(w, "Ada", seq([15]))

    assert msg =~ "supera la salvación de Sabiduría"
    assert msg =~ "14 vs CD 13"
    refute msg =~ "concentra"
    refute paralyzed?(next, "Ada")
    assert next.characters["Vex"].concentrating == nil
    assert next.spell_slots["Vex"][2] == 1
    assert spent?() == []
  end

  test "un beast con raza se rechaza sin mutar ni tirar" do
    beast = humanoid("Lobo", race: "beast")
    w = world([beast])

    assert {:error, msg} = Actions.spell(w, "Vex", "hold person", "Lobo", &no_roll/1, nil)
    assert msg =~ "humanoides"
    assert w.spell_slots["Vex"][2] == 2
    refute paralyzed?(w, "Lobo")
  end

  test "sin raza se acepta cualquier criatura" do
    w = world([humanoid("Nube", race: nil, wis: 8)])
    {_msg, next} = cast!(w, "Nube", seq([10]))
    assert paralyzed?(next, "Nube")
  end

  test "goblinoid entra; upcast de objetivos no" do
    goblin = humanoid("Gob", race: "goblinoid", wis: 8)
    w = world([goblin, humanoid("Ada")])

    assert {:error, _} =
             Actions.spell(w, "Vex", "hold person", "Gob", &no_roll/1, nil, 2, ["Ada"])

    assert w.spell_slots["Vex"][2] == 2
    {_msg, next} = cast!(w, "Gob", seq([10]))
    assert paralyzed?(next, "Gob")
  end

  test "Twinned paraliza a los dos que fallan y consume la opción" do
    w = world([humanoid("Ada", wis: 8), humanoid("Bea", wis: 8)])
    {:ok, w} = World.set_metamagic("Vex", %{option: "twinned", target: "Bea"}).(w)
    {msg, next} = cast!(w, "Ada", seq([10, 10]))

    assert msg =~ "Twinned"
    assert paralyzed?(next, "Ada")
    assert paralyzed?(next, "Bea")
    assert next.characters["Vex"].metamagic == nil
    assert next.spell_slots["Vex"][2] == 1
    assert spent?() == []
  end

  test "el inicio de un turno nuevo repite la salvación; re-selección y reacción no" do
    w = world([humanoid("Ada", wis: 8), humanoid("Bea")])
    {:ok, w} = World.begin_combat(["Vex", "Ada", "Bea"]).(w)
    {:ok, w} = World.set_current_combatant("Vex").(w)
    {_msg, w} = cast!(w, "Ada", seq([10]))
    assert paralyzed?(w, "Ada")

    {:ok, w} = World.next_round().(w)
    {:ok, stayed} = World.set_current_combatant("Ada", "main", seq([10])).(w)
    assert paralyzed?(stayed, "Ada")
    assert stayed.log |> Enum.map(&elem(&1, 1)) |> Enum.join(" ") =~ "sigue paralizado"
    assert spent?() == []

    {:ok, same} = World.set_current_combatant("Ada", "main", &no_roll/1).(stayed)
    assert paralyzed?(same, "Ada")

    {:ok, reaction} = World.set_current_combatant("Ada", "reaction", &no_roll/1).(stayed)
    assert paralyzed?(reaction, "Ada")

    {:ok, other} = World.next_round().(stayed)
    {:ok, other} = World.set_current_combatant("Bea", "main", &no_roll/1).(other)
    assert paralyzed?(other, "Ada")

    {:ok, freed} = World.set_current_combatant("Ada", "main", seq([15])).(other)
    refute paralyzed?(freed, "Ada")
    assert spent?() == []
  end

  test "paralizado auto-falla DES y un melee que impacta es crítico" do
    target = humanoid("Ada", wis: 8, ac: 10)
    w = world([target])
    {_msg, w} = cast!(w, "Ada", seq([10]))
    ada = w.characters["Ada"]

    assert Conditions.save_mode(ada, :dex) == :auto_fail
    assert Conditions.save_mode(ada, :str) == :auto_fail
    assert Conditions.save_mode(ada, :wis) == {:roll, :normal}

    sword = %Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
    hero = Character.new(name: "Thane", hp: 20, max_hp: 20, str: 16, weapons: [sword])
    w = %{w | characters: Map.put(w.characters, "Thane", hero)}

    assert {:ok, msg, _} = Actions.attack(w, "Thane", "Ada", "longsword", seq([15, 8, 4, 3]))
    assert msg =~ "CRÍTICO"
    assert msg =~ "(ventaja)"
    assert spent?() == []
  end

  test "romper la concentración limpia paralyzed en todas las rutas" do
    for route <- [:drop, :zero, :rage, :incap, :clock] do
      w = world([humanoid("Ada", wis: 8)])
      {_msg, w} = cast!(w, "Ada", seq([10]))
      assert paralyzed?(w, "Ada")

      {:ok, w} =
        case route do
          :drop -> World.clear_concentration("Vex").(w)
          :zero -> World.apply_damage("Vex", 50).(w)
          :rage -> World.set_raging("Vex", true).(w)
          :incap -> World.apply_condition("Vex", "incapacitated").(w)
          :clock -> World.advance_time(60).(w)
        end

      refute paralyzed?(w, "Ada"), "#{route}"
      assert w.characters["Vex"].concentrating == nil, "#{route}"
    end
  end

  test "un kobold reptilian es humanoide y la aura D61 suma a la salvación" do
    kobold = humanoid("Kob", race: "reptilian", wis: 8)
    {_msg, next} = cast!(world([kobold]), "Kob", seq([10]))
    assert paralyzed?(next, "Kob")

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

    ada = humanoid("Ada", side: "pc", wis: 10)
    w = world([ada, paladin])
    {msg, next} = cast!(w, "Ada", seq([10]))
    assert msg =~ "13 vs CD 13"
    assert msg =~ "+3 aura"
    refute paralyzed?(next, "Ada")
    assert spent?() == []
  end

  test "un gnomo tira la paralización con ventaja y el fighter gasta Indomitable" do
    gnome = humanoid("Nim", race: "gnome", wis: 10)
    {msg, next} = cast!(world([gnome]), "Nim", seq([4, 18]))
    assert msg =~ "Astucia gnoma"
    assert msg =~ "18 vs CD 13"
    refute paralyzed?(next, "Nim")
    assert spent?() == []

    fighter = humanoid("Ada", class: "fighter", level: 9, wis: 10, indomitable_used: false)
    {msg, next} = cast!(world([fighter]), "Ada", seq([2, 18]))
    assert msg =~ "Indomitable"
    refute paralyzed?(next, "Ada")
    assert next.characters["Ada"].indomitable_used
    assert spent?() == []
  end

  test "la inspiración puede salvar y Heightened impone desventaja" do
    inspired = humanoid("Ada", wis: 10, inspired: true)
    {msg, next} = cast!(world([inspired]), "Ada", seq([8, 6]))
    assert msg =~ "+6 inspiración"
    refute paralyzed?(next, "Ada")
    refute next.characters["Ada"].inspired
    assert spent?() == []

    w = world([humanoid("Ada", wis: 10)])
    {:ok, w} = World.set_metamagic("Vex", %{option: "heightened", target: "Ada"}).(w)
    {msg, next} = cast!(w, "Ada", seq([18, 3]))
    assert msg =~ "Heightened"
    assert msg =~ "3 vs CD 13"
    assert paralyzed?(next, "Ada")
    assert next.characters["Vex"].metamagic == nil
    assert spent?() == []
  end

  test "al liberar al último objetivo suelta la concentración del lanzador" do
    w = world([humanoid("Ada", wis: 8)])
    {:ok, w} = World.begin_combat(["Vex", "Ada"]).(w)
    {:ok, w} = World.set_current_combatant("Vex").(w)
    {_msg, w} = cast!(w, "Ada", seq([10]))
    assert w.characters["Vex"].concentrating == "hold person"

    {:ok, w} = World.next_round().(w)
    {:ok, w} = World.set_current_combatant("Ada", "main", seq([15])).(w)
    refute paralyzed?(w, "Ada")
    assert w.characters["Vex"].concentrating == nil
    assert spent?() == []
  end

  test "Codec conserva la entrada con fuente y CD" do
    w = world([humanoid("Ada", wis: 8)])
    {_msg, w} = cast!(w, "Ada", seq([10]))
    again = Codec.decode(Codec.encode(w))
    entry = Enum.find(again.characters["Ada"].conditions, &(&1["condition"] == "paralyzed"))
    assert entry["source"] == "hold_person:Vex"
    assert entry["dc"] == 13
    assert again.characters["Vex"].concentrating == "hold person"
  end

  test "la salvación deja UN grupo :save en el RollLog con su dado exacto" do
    # Fix de revisión cruzada (oleada E): la salvación de condition-spells
    # debe llegar al RollLog vivo con el mismo patrón que el resto.
    alias Dragonex.RollLog

    w = world([humanoid("Ada", wis: 8)])
    {:ok, rec} = RollLog.start()
    log = %RollLog{base: seq([10]), recorder: rec}

    assert {:ok, _msg, _change} =
             Actions.spell(w, "Vex", "hold person", "Ada", seq([10]), log)

    [save] = RollLog.entries(rec)
    assert save.who == "Ada" and save.kind == :save
    assert save.reason =~ "Sabiduría"
    assert save.dice == [[20, 10]]
    assert save.total == 9 and save.against == ["dc", 13]
    assert save.outcome == :failure
    RollLog.stop(rec)
  end
end
