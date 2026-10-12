defmodule Dragonex.NegativeWeaponDamageTest do
  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, PCAgent, RollLog, Weapon, World}
  alias Dragonex.Rules.Combat
  alias ExAgent.{Models.Test, Session}
  alias ExAgent.Session.SharedState

  defp club(opts \\ []) do
    struct(
      Weapon,
      Keyword.merge(
        [name: "club", dice: "1d4", attack_ability: :str, damage_type: "bludgeoning"],
        opts
      )
    )
  end

  defp actor(opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: "A", class: "fighter", str: 6, dex: 6, hp: 10, max_hp: 10, weapons: [club()]],
        opts
      )
    )
  end

  defp target(opts \\ []) do
    Character.new(Keyword.merge([name: "T", side: "enemy", hp: 10, max_hp: 10, ac: 10], opts))
  end

  defp world(attacker, victim) do
    world = World.new(characters: %{"A" => attacker, "T" => victim}) |> World.init_spell_slots()
    {:ok, world} = World.begin_combat(["A", "T"]).(world)
    {:ok, world} = World.set_current_combatant("A").(world)
    world
  end

  defp seq(values) do
    Process.put(:negative_damage_rolls, values)

    fn sides ->
      [value | rest] = Process.get(:negative_damage_rolls)
      assert value in 1..sides
      Process.put(:negative_damage_rolls, rest)
      value
    end
  end

  defp attack(world, values, mode \\ :normal) do
    {:ok, recorder} = RollLog.start()
    roller = seq(values)
    log = %RollLog{base: roller, recorder: recorder}

    try do
      assert {:ok, message, change} = Actions.attack(world, "A", "T", "club", roller, mode, log)
      assert {:ok, next} = change.(world)
      assert Process.get(:negative_damage_rolls) == []
      assert Codec.decode(Jason.decode!(Jason.encode!(Codec.encode(next)))) == next
      {message, next, RollLog.entries(recorder)}
    after
      RollLog.stop(recorder)
    end
  end

  test "normal and critical weapon damage may be zero but never negative" do
    weak = actor(str: 3)
    assert Combat.damage_roll(weak, club(), :hit, seq([1])) == 0
    assert Combat.damage_roll(weak, club(), :crit, seq([1, 1])) == 0
    assert Combat.damage_roll(weak, club(), :crit, seq([4, 4])) == 4
  end

  test "zero damage spends the attack without consuming temporary HP or rolling concentration" do
    before = world(actor(), target(temp_hp: 5, concentrating: "bless"))
    {message, next, [hit, damage]} = attack(before, [15, 1])
    assert message =~ "por 0 de daño"
    assert hit.outcome == :hit
    assert damage.total == 0
    assert damage.raw_total == -1
    assert damage.dice == [[4, 1]]
    assert next.characters["T"] == before.characters["T"]
    assert next.turn_state["A"]["action"] == true
    refute next.turn_state["T"]["damaged"]
  end

  test "a zero damage critical against a downed PC does not add death save failures" do
    before = world(actor(str: 3), target(side: "pc", hp: 0))
    {message, next, [hit, damage]} = attack(before, [20, 1, 1])
    assert message =~ "CRÍTICO"
    assert message =~ "por 0 de daño"
    assert hit.outcome == :crit
    assert damage.total == 0
    assert next.characters["T"].death_saves == %{successes: 0, fails: 0}
  end

  test "rage joins the ability penalty before applying the zero damage minimum" do
    before = world(actor(class: "barbarian", str: 3, raging: true), target())
    {message, next, [_, damage]} = attack(before, [15, 3])
    # 3 on the weapon - 4 STR + 2 rage = 1, not 2.
    assert damage.total == 1
    assert message =~ "por 1 de daño"
    assert next.characters["T"].hp == 9
  end

  test "rage cannot leave a negative total in the result or dice group" do
    before = world(actor(class: "barbarian", str: 3, raging: true), target())
    {message, next, [_, damage]} = attack(before, [15, 1])
    assert damage.total == 0
    assert message =~ "por 0 de daño"
    assert next.characters["T"].hp == 10
  end

  test "Hunter's Mark and the weapon use one damage total before resistance" do
    before =
      world(
        actor(class: "ranger", concentrating: "hunter's mark:T"),
        target(damage_resistances: ["bludgeoning"])
      )

    {message, next, [_, damage]} = attack(before, [15, 1, 3])
    # 1 - 2 + 3 = 2, then resistance halves the same-type total to 1.
    assert damage.total == 2
    assert message =~ "por 2 de daño"
    assert next.characters["T"].hp == 9
  end

  test "Sneak Attack preserves the negative weapon subtotal before summing its dice" do
    before = world(actor(class: "rogue", weapons: [club(finesse: true)]), target())
    {message, next, [_, damage]} = attack(before, [15, 16, 1, 2], :advantage)
    assert damage.total == 1
    assert message =~ "por 1 de daño"
    assert next.characters["T"].hp == 9
    assert next.turn_state["A"]["sneak_turn"] == "1:A"
  end

  test "zero weapon damage still resolves a separate radiant Smite and spends one slot" do
    before = world(actor(class: "paladin", level: 2), target())
    {:ok, before} = World.set_smite_slot("A", 1).(before)
    {message, next, [_, weapon_damage, smite_damage]} = attack(before, [15, 1, 2, 2])
    assert weapon_damage.total == 0
    assert smite_damage.total == 4
    assert message =~ "por 0 de daño"
    assert next.characters["T"].hp == 6
    assert before.spell_slots["A"][1] == 2
    assert next.spell_slots["A"][1] == 1
    assert next.characters["A"].smite_slot == nil
  end

  test "a scripted PC resolves its advertised Smite and attack tools without a retry or negative result" do
    paladin = actor(class: "paladin", level: 2)
    before = world(paladin, target())
    session = start_supervised!({Session, shared_state: before, participants: [p("A")]})
    assert {:ok, "A"} = Session.start(session)
    draws = start_supervised!({Agent, fn -> [15, 1, 2, 2] end})

    roller = fn sides ->
      value = Agent.get_and_update(draws, fn [value | rest] -> {value, rest} end)
      assert value in 1..sides
      value
    end

    model = %Test{
      script: [
        tool_calls([call("divine_smite", %{"who" => "A", "slot_level" => 1})]),
        tool_calls([
          call("make_attack", %{
            "attacker" => "A",
            "target" => "T",
            "weapon" => "club",
            "mode" => "normal"
          })
        ]),
        fn messages, _ ->
          assert inspect(messages, limit: :infinity) =~ "por 0 de daño"
          "Mi arma no hiere, pero la luz alcanza al enemigo."
        end
      ]
    }

    agent = ExAgent.new(model: model, tools: PCAgent.tools(), instructions: "Actúa como A.")

    assert {:ok, _} =
             ExAgent.run(agent, "Actúa en tu turno.",
               deps: %{state: SharedState.new(session, "A"), roller: roller}
             )

    next = Session.read_state(session)
    assert next.characters["T"].hp == 6
    assert next.spell_slots["A"][1] == 1
    assert next.turn_state["A"]["action"] == true
    assert Agent.get(draws, & &1) == []
  end
end
