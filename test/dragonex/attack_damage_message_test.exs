defmodule Dragonex.AttackDamageMessageTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Archetypes, Character, RollLog, Weapon, World}

  @roll_key {__MODULE__, :rolls}

  defp sword do
    %Weapon{name: "sword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
  end

  defp shortsword do
    %Weapon{
      name: "shortsword",
      dice: "1d6",
      damage_type: "piercing",
      attack_ability: :dex,
      finesse: true
    }
  end

  defp actor(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "A",
          class: "fighter",
          race: "human",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 16,
          str: 16,
          dex: 16,
          side: "pc",
          weapons: [sword()]
        ],
        opts
      )
    )
  end

  defp world(actor) do
    target = Character.new(name: "T", class: "monster", side: "enemy", hp: 50, max_hp: 50, ac: 12)

    World.new(characters: %{"A" => actor, "T" => target, "B" => Archetypes.fighter(name: "B")})
    |> World.init_spell_slots()
  end

  defp attack(before, weapon, values) do
    Process.put(@roll_key, values)

    roller = fn sides ->
      [value | rest] = Process.get(@roll_key)
      assert value in 1..sides
      Process.put(@roll_key, rest)
      value
    end

    {:ok, recorder} = RollLog.start()
    roll_log = %RollLog{base: roller, recorder: recorder}

    try do
      assert {:ok, message, change} =
               Actions.attack(before, "A", "T", weapon, roller, :normal, roll_log)

      assert {:ok, next} = change.(before)
      assert Process.get(@roll_key) == []
      {message, next, RollLog.entries(recorder)}
    after
      RollLog.stop(recorder)
      Process.delete(@roll_key)
    end
  end

  test "the thirteen damage example includes five sneak damage once" do
    before = world(actor(class: "rogue", weapons: [shortsword()]))
    {message, next, [hit, damage]} = attack(before, "shortsword", [19, 5, 5])
    assert message =~ "por 13 de daño perforante en total (incluye 5 sneak)"
    refute message =~ "+5 sneak"
    assert hit.outcome == :hit and damage.total == 13
    assert damage.dice == [[6, 5], [6, 5]]
    assert next.characters["T"].hp == 37
    assert next.characters["A"] == before.characters["A"]
  end

  test "rage is included in the physical total without rolling another die" do
    before = world(actor(class: "barbarian", raging: true))
    {message, next, [_, damage]} = attack(before, "sword", [19, 4])
    assert message =~ "por 9 de daño cortante en total (incluye 2 furia)"
    assert damage.total == 9 and damage.dice == [[8, 4]]
    assert next.characters["T"].hp == 41
    assert next.characters["A"] == before.characters["A"]
  end

  test "Hunter's Mark is included rather than added again to the weapon total" do
    before = world(actor(class: "ranger", level: 2, concentrating: "hunter's mark:T"))
    {message, next, [_, damage]} = attack(before, "sword", [19, 4, 3])
    assert message =~ "por 10 de daño cortante en total (incluye 3 presa marcada)"
    assert damage.total == 10 and damage.dice == [[8, 4], [6, 3]]
    assert next.characters["T"].hp == 40
    assert next.spell_slots == before.spell_slots
  end

  test "a critical combines Savage and sneak into one labelled physical total" do
    before = world(actor(class: "rogue", race: "half-orc", weapons: [shortsword()]))
    {message, next, [hit, damage]} = attack(before, "shortsword", [20, 2, 3, 4, 5, 6])
    assert message =~ "CRÍTICO"
    assert message =~ "por 23 de daño perforante en total (incluye 4 Savage, 11 sneak)"
    assert hit.outcome == :crit and damage.total == 23
    assert damage.dice == [[6, 2], [6, 3], [6, 4], [6, 5], [6, 6]]
    assert next.characters["T"].hp == 27
  end

  test "Extra Attack reports each hit's included rage without merging or paying twice" do
    before = world(actor(class: "barbarian", level: 5, raging: true))
    {message, next, [_, first, _, second]} = attack(before, "sword", [19, 4, 18, 3])
    assert message =~ "2 golpes"
    assert message =~ "por 9 de daño cortante en total (incluye 2 furia)"
    assert message =~ "por 8 de daño cortante en total (incluye 2 furia)"
    assert first.total == 9 and second.total == 8
    assert next.characters["T"].hp == 33
    assert next.characters["A"] == before.characters["A"]
  end

  test "Divine Smite stays a separate radiant addition and spends one slot" do
    before = world(actor(class: "paladin", level: 2))
    assert {:ok, armed} = World.start_smite("A", 1).(before)
    {message, next, [_, physical, radiant]} = attack(armed, "sword", [19, 4, 2, 3])
    assert message =~ "por 7 de daño cortante en total"
    assert message =~ "+5 smite 2d8 radiante, adicional"
    refute message =~ "incluye 5 smite"
    assert physical.total == 7 and radiant.total == 5
    assert next.characters["T"].hp == 38
    assert next.spell_slots["A"][1] == armed.spell_slots["A"][1] - 1
    assert next.characters["A"].smite_slot == nil
  end

  test "bardic inspiration belongs to the attack roll instead of the damage total" do
    before = world(actor(inspired: true))
    {message, next, [hit, damage]} = attack(before, "sword", [5, 3, 4])
    assert message =~ "por 7 de daño cortante en total"
    assert message =~ "ataque: incluye 3 inspiración"
    assert hit.total == 13 and damage.total == 7
    assert next.characters["T"].hp == 43
    refute next.characters["A"].inspired
  end

  test "a miss can spend inspiration but never invents a damage total" do
    before = world(actor(inspired: true))
    {message, next, [hit]} = attack(before, "sword", [5, 1])
    assert message =~ "fallo"
    assert message =~ "ataque: incluye 1 inspiración"
    refute message =~ "de daño"
    assert hit.outcome == :miss and hit.total == 11
    assert next.characters["T"].hp == 50
    refute next.characters["A"].inspired
  end
end
