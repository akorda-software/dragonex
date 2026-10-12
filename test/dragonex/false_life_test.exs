defmodule Dragonex.FalseLifeTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, RollLog, World}
  alias Dragonex.Heroes.Spells

  defp world do
    c =
      Character.new(
        name: "C",
        class: "wizard",
        level: 17,
        int: 20,
        hp: 5,
        max_hp: 30,
        spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
      )

    a = Character.new(name: "A", hp: 20, max_hp: 20)
    World.new(characters: %{"C" => c, "A" => a}, spell_slots: %{"C" => %{1 => 3, 2 => 2, 9 => 1}})
  end

  test "level two generates 1d4+9 temp HP, with exactly one die and no INT modifier" do
    w = world()
    Process.put(:false_life_rolls, 0)

    roller = fn sides ->
      assert sides == 4
      Process.put(:false_life_rolls, Process.get(:false_life_rolls) + 1)
      3
    end

    assert {:ok, _, change} = Actions.spell(w, "C", "false life", "C", roller, nil, 2)
    assert {:ok, next} = change.(w)
    assert next.characters["C"].temp_hp == 12
    assert next.characters["C"].hp == 5
    assert next.spell_slots["C"] == %{1 => 3, 2 => 1, 9 => 1}
    assert Process.get(:false_life_rolls) == 1
  end

  defp cast(w, level \\ nil, die \\ 4) do
    assert {:ok, msg, change} =
             Actions.spell(w, "C", "false life", "C", fn 4 -> die end, nil, level)

    assert {:ok, next} = change.(w)
    {next, msg}
  end

  for {level, expected} <- [{1, 8}, {3, 18}, {9, 48}] do
    test "level #{level} grants #{expected} temporary HP for one hour" do
      w = world()
      w = put_in(w.spell_slots["C"][unquote(level)], 1)
      {next, msg} = cast(w, unquote(level))
      assert next.characters["C"].temp_hp == unquote(expected)
      assert next.effect_expiries["C"]["temp_hp"] == 3600
      assert next.spell_slots["C"][unquote(level)] == 0
      assert msg =~ "#{unquote(expected)} pg temporales"
      if unquote(level) > 1, do: assert(msg =~ "(nivel #{unquote(level)})")
    end
  end

  test "base casting is compatible and uses an action without replacing concentration" do
    {:ok, w} = World.set_concentration("C", "bless").(world())
    {:ok, w} = World.begin_combat(["C", "A"]).(w)
    {:ok, w} = World.set_current_combatant("C").(w)
    {next, _} = cast(w)
    assert next.characters["C"].temp_hp == 8
    assert next.characters["C"].concentrating == "bless"
    assert next.turn_state["C"]["action"]
    refute next.turn_state["C"]["bonus"]
    assert {:error, _} = Actions.spell(next, "C", "false life", "C", fn _ -> flunk("no roll") end)
  end

  test "smaller and equal rolls spend slots but do not stack or renew the original expiry" do
    {w, _} = cast(world(), 2)
    assert w.characters["C"].temp_hp == 13
    {:ok, w} = World.advance_time(100).(w)

    for level <- [1, 2] do
      {next, msg} = cast(w, level)
      assert next.characters["C"].temp_hp == 13
      assert next.effect_expiries["C"]["temp_hp"] == 3600
      assert next.spell_slots["C"][level] == w.spell_slots["C"][level] - 1
      assert msg =~ "no se acumulan"
    end
  end

  test "a larger value replaces the source and starts a new hour; damage absorbs temp HP first" do
    {w, _} = cast(world())
    {:ok, w} = World.advance_time(100).(w)
    {next, _} = cast(w, 2)
    assert next.characters["C"].temp_hp == 13
    assert next.effect_expiries["C"]["temp_hp"] == 3700
    {:ok, damaged} = World.apply_damage("C", 10).(next)
    assert damaged.characters["C"].temp_hp == 3
    assert damaged.characters["C"].hp == 5
    {:ok, expired} = World.advance_time(3600).(damaged)
    assert expired.characters["C"].temp_hp == 0
    assert expired.characters["C"].hp == 5
  end

  test "a stronger untimed source stays untimed; long rest removes temporary HP" do
    {:ok, w} = World.apply_temp_hp("C", 30).(world())
    {next, _} = cast(w, 2)
    assert next.characters["C"].temp_hp == 30
    refute Map.has_key?(Map.get(next.effect_expiries, "C", %{}), "temp_hp")
    {:ok, _, rest} = Actions.long_rest(next, "C")
    {:ok, rested} = rest.(next)
    assert rested.characters["C"].temp_hp == 0
  end

  test "self-only validation rejects another target and preserves armed metamagic" do
    for option <- ["twinned", "empowered", "heightened"] do
      w = put_in(world().characters["C"].metamagic, %{option: option, target: "A"})
      assert {:error, _} = Actions.spell(w, "C", "false life", "A", fn _ -> flunk("no roll") end)
      {next, _} = cast(w, 2)
      assert next.characters["C"].temp_hp == 13
      assert next.characters["A"].temp_hp == 0
      assert next.characters["C"].metamagic == w.characters["C"].metamagic
    end
  end

  test "invalid levels, missing slot, additional targets and stale resources are rejected" do
    w = world()

    for level <- [0, 10, 2.5, "2"] do
      assert {:error, _} =
               Actions.spell(w, "C", "false life", "C", fn _ -> flunk("no roll") end, nil, level)
    end

    assert {:error, _} =
             Actions.spell(w, "C", "false life", "C", fn _ -> flunk("no roll") end, nil, 4)

    assert {:error, _} =
             Actions.spell(w, "C", "false life", "C", fn _ -> flunk("no roll") end, nil, 2, ["A"])

    {:ok, _, change} = Actions.spell(w, "C", "false life", "C", fn 4 -> 3 end, nil, 2)
    assert {:error, _} = change.(put_in(w.spell_slots["C"][2], 0))
    assert {:error, _} = change.(put_in(w.characters["C"].hp, 0))
  end

  test "RollLog reports one d4 and the scaled total; JSON retains the original expiry" do
    w = world()
    roller = fn 4 -> 2 end
    {:ok, recorder} = RollLog.start()
    log = %RollLog{base: roller, recorder: recorder}
    {:ok, _, change} = Actions.spell(w, "C", "false life", "C", roller, log, 2)
    {:ok, next} = change.(w)
    [entry] = RollLog.entries(recorder)
    assert entry.total == 11
    assert length(entry.dice) == 1
    RollLog.stop(recorder)
    {:ok, next} = World.advance_time(3599).(next)
    loaded = next |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert loaded.characters["C"].temp_hp == 11
    assert loaded.effect_expiries["C"]["temp_hp"] == 3600
    {:ok, expired} = World.advance_time(1).(loaded)
    assert expired.characters["C"].temp_hp == 0
  end
end
