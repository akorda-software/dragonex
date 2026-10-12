defmodule Dragonex.DamagePipelineTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, World, Weapon}

  defp seq(values) do
    Process.put(:damage_rolls, values)

    fn sides ->
      [n | rest] = Process.get(:damage_rolls)
      assert n in 1..sides
      Process.put(:damage_rolls, rest)
      n
    end
  end

  defp world(target, level \\ 1) do
    attacker =
      Character.new(
        name: "A",
        class: "fighter",
        level: level,
        hp: 30,
        max_hp: 30,
        weapons: [
          %Weapon{name: "sword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
        ]
      )

    World.new(characters: %{"A" => attacker, "T" => target})
  end

  test "temporary HP prevent premature termination of Extra Attack" do
    t = Character.new(name: "T", hp: 3, max_hp: 3, temp_hp: 10, ac: 10)
    w = world(t, 5)
    r = seq([15, 4, 15, 4])
    {:ok, _, change} = Actions.attack(w, "A", "T", "sword", r)
    assert {:ok, next} = change.(w)
    assert next.characters["T"].hp == 3
    assert next.characters["T"].temp_hp == 2
    assert Process.get(:damage_rolls) == []
  end

  test "Relentless Endurance keeps concentration subject to a save and rolls only once" do
    t =
      Character.new(
        name: "T",
        race: "half-orc",
        hp: 3,
        max_hp: 12,
        ac: 10,
        concentrating: "bless"
      )

    w = world(t)
    r = seq([15, 4, 12])
    {:ok, message, change} = Actions.attack(w, "A", "T", "sword", r)
    assert {:ok, next} = change.(w)
    assert next.characters["T"].hp == 1
    assert next.characters["T"].concentrating == "bless"
    assert message =~ "mantiene la concentración"
    assert Process.get(:damage_rolls) == []
    assert {:ok, ^next} = change.(w)
    assert Process.get(:damage_rolls) == []
  end

  test "direct damage also performs concentration saves" do
    t = Character.new(name: "T", hp: 20, max_hp: 20, concentrating: "bless")
    w = world(t)
    {:ok, next} = World.apply_damage("T", 2, "fire", seq([2])).(w)
    assert next.characters["T"].concentrating == nil
    assert Process.get(:damage_rolls) == []
  end

  test "a prepared damage result refuses a changed target instead of replaying random rolls" do
    t = Character.new(name: "T", hp: 20, max_hp: 20, ac: 10)
    w = world(t)
    {:ok, _, change} = Actions.attack(w, "A", "T", "sword", seq([15, 4]))
    {:ok, altered} = World.apply_damage("T", 1).(w)
    assert {:error, _} = change.(altered)
  end

  test "Uncanny Dodge changes both HP loss and concentration DC" do
    t =
      Character.new(
        name: "T",
        class: "rogue",
        level: 5,
        hp: 50,
        max_hp: 50,
        uncanny_dodge: true,
        concentrating: "bless"
      )

    {:ok, w} = World.apply_damage("T", 40, "fire", seq([10])).(world(t))
    assert w.characters["T"].hp == 30
    assert w.characters["T"].concentrating == "bless"
    refute w.characters["T"].uncanny_dodge
    assert Process.get(:damage_rolls) == []
  end

  test "prepared concentration cannot reuse inspiration consumed after preparation" do
    t =
      Character.new(name: "T", hp: 20, max_hp: 20, ac: 10, inspired: true, concentrating: "bless")

    w = world(t)
    {:ok, message, change} = Actions.attack(w, "A", "T", "sword", seq([15, 4, 6, 4]))
    assert message =~ "mantiene la concentración"
    {:ok, altered} = World.set_inspired("T", false).(w)
    assert {:error, _} = change.(altered)
    assert Process.get(:damage_rolls) == []
  end

  test "prepared concentration cannot reuse Indomitable consumed after preparation" do
    t =
      Character.new(
        name: "T",
        class: "fighter",
        level: 9,
        hp: 20,
        max_hp: 20,
        ac: 10,
        concentrating: "bless"
      )

    w = world(t)
    {:ok, message, change} = Actions.attack(w, "A", "T", "sword", seq([15, 4, 2, 12]))
    assert message =~ "Indomitable"
    {:ok, altered} = World.set_indomitable("T", true).(w)
    assert {:error, _} = change.(altered)
    assert Process.get(:damage_rolls) == []
  end

  test "Wild Shape reversion precedes the concentration save and carries only excess" do
    t =
      Character.new(
        name: "T",
        class: "druid",
        level: 2,
        hp: 12,
        max_hp: 20,
        con: 12,
        concentrating: "bless",
        wild_shape_uses: 2
      )

    w = world(t)
    {:ok, _, transform} = Actions.wild_shape(w, "T", "wolf")
    {:ok, w} = transform.(w)
    beast_hp = w.characters["T"].hp
    {:ok, w} = World.apply_damage("T", beast_hp + 3, "fire", seq([12])).(w)
    assert w.characters["T"].wild_shape == nil
    assert w.characters["T"].hp == 9
    assert w.characters["T"].concentrating == "bless"
    assert Process.get(:damage_rolls) == []
  end

  test "weapon and radiant components of a single hit cause one concentration save" do
    t =
      Character.new(
        name: "T",
        hp: 40,
        max_hp: 40,
        concentrating: "bless",
        damage_resistances: ["slashing"]
      )

    {:ok, w} =
      World.apply_damage("T", 10, "slashing", seq([10]), additional_damage: [{15, "radiant"}]).(
        world(t)
      )

    assert w.characters["T"].hp == 20
    assert w.characters["T"].concentrating == "bless"
    assert Process.get(:damage_rolls) == []
  end
end
