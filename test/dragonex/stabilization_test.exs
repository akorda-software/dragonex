defmodule Dragonex.StabilizationTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, World}

  defp stabilize do
    c = Character.new(name: "Hero", hp: 0, max_hp: 12, death_saves: %{successes: 2, fails: 2})
    w = World.new(characters: %{"Hero" => c})
    {:ok, w} = World.apply_death_save("Hero", {:success, 12, 0, 1}).(w)
    w
  end

  test "stabilization clears old failures and survives serialization" do
    w = stabilize() |> Codec.encode() |> Codec.decode()
    assert w.characters["Hero"].death_saves == %{successes: 3, fails: 0}
    assert {:error, message} = Actions.death_save(w, "Hero", fn _ -> 10 end)
    assert message =~ "estable"
  end

  test "damage ends stability and death saves resume with fresh counters" do
    {:ok, w} = World.apply_damage("Hero", 1).(stabilize())
    assert w.characters["Hero"].death_saves == %{successes: 0, fails: 1}
    refute World.dead?(w, "Hero")
    assert {:ok, _, _} = Actions.death_save(w, "Hero", fn _ -> 10 end)
  end

  test "critical damage after stabilization counts two new failures, not old failures" do
    {:ok, w} = World.apply_damage("Hero", 1, nil, nil, crit: true).(stabilize())
    assert w.characters["Hero"].death_saves == %{successes: 0, fails: 2}
    refute World.dead?(w, "Hero")
  end

  test "zero damage preserves stability" do
    w = stabilize()
    assert {:ok, ^w} = World.apply_damage("Hero", 0).(w)
  end

  test "damage to a stable character from an older save discards stale failures" do
    w = stabilize()
    c = %{w.characters["Hero"] | death_saves: %{successes: 3, fails: 2}}
    w = %{w | characters: %{"Hero" => c}} |> Codec.encode() |> Codec.decode()
    {:ok, w} = World.apply_damage("Hero", 1).(w)
    assert w.characters["Hero"].death_saves == %{successes: 0, fails: 1}
  end
end
