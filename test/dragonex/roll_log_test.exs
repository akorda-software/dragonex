defmodule Dragonex.RollLogTest do
  @moduledoc """
  The per-beat roll recorder: each die roll is captured in a structured group
  with who/why/dice/total/against/outcome, JSON-safe for the timeline.
  """

  use ExUnit.Case, async: true

  alias Dragonex.RollLog

  defp always(n), do: fn _sides -> n end

  test "open/close captures the dice, total and outcome as one JSON-safe group" do
    {:ok, rec} = RollLog.start()
    log = %RollLog{base: always(14), recorder: rec}

    {roller, close} = RollLog.open(log, nil, "Thane", :attack, "ataque con longsword")
    # The attack rolls a single d20; the recording roller returns the base value.
    assert 14 = roller.(20)
    RollLog.close(close, total: 18, against: {:ac, 15}, outcome: :hit)

    [entry] = RollLog.entries(rec)
    assert entry.who == "Thane"
    assert entry.kind == :attack
    assert entry.reason == "ataque con longsword"
    # dice stored JSON-safe as [[sides, value]]
    assert entry.dice == [[20, 14]]
    assert entry.total == 18
    # against tuple normalized to a JSON-safe list
    assert entry.against == ["ac", 15]
    assert entry.outcome == :hit

    # The entry round-trips through Jason (it lands in jsonb).
    assert {:ok, _} = Jason.encode(entry)

    RollLog.stop(rec)
  end

  test "multiple dice in a group (e.g. 2d6 damage) are all recorded" do
    {:ok, rec} = RollLog.start()
    log = %RollLog{base: always(4), recorder: rec}

    {roller, close} = RollLog.open(log, nil, "Thane", :damage, "daño slashing")
    assert 4 = roller.(6)
    assert 4 = roller.(6)
    RollLog.close(close, total: 11, against: nil, outcome: nil)

    [entry] = RollLog.entries(rec)
    assert entry.dice == [[6, 4], [6, 4]]
    assert entry.total == 11
    assert entry.against == nil

    RollLog.stop(rec)
  end

  test "concurrent groups don't collide (each open gets its own roller)" do
    {:ok, rec} = RollLog.start()
    log = %RollLog{base: always(10), recorder: rec}

    {r1, c1} = RollLog.open(log, nil, "Thane", :attack, "Thane ataca")
    {r2, c2} = RollLog.open(log, nil, "goblin", :attack, "goblin ataca")
    # Interleave rolls from both groups.
    _ = r1.(20)
    _ = r2.(20)
    _ = r1.(8)
    RollLog.close(c1, total: 14, against: {:ac, 13}, outcome: :hit)
    RollLog.close(c2, total: 12, against: {:ac, 16}, outcome: :miss)

    [e1, e2] = RollLog.entries(rec)
    # Thane's group kept only Thane's dice, goblin's only goblin's.
    assert e1.who == "Thane" and e1.dice == [[20, 10], [8, 10]] and e1.outcome == :hit
    assert e2.who == "goblin" and e2.dice == [[20, 10]] and e2.outcome == :miss

    RollLog.stop(rec)
  end

  test "without a recorder, open degrades to a pass-through (no logging)" do
    {roller, close} = RollLog.open(nil, always(7), "x", :roll, "tirada")
    assert 7 = roller.(20)
    assert nil == RollLog.close(close, total: 7)
  end

  test "a damage minimum retains its actual subtotal through buffering and JSON" do
    {:ok, rec} = RollLog.start()
    log = RollLog.for_tool(%RollLog{base: always(1), recorder: rec}, make_ref())
    {roller, closer} = RollLog.open(log, nil, "Arden", :damage, "daño del arma")
    assert roller.(4) == 1
    entry = RollLog.close(closer, total: 0, raw_total: -1)
    assert entry.raw_total == -1
    assert RollLog.pending(log) == [entry]
    assert Jason.decode!(Jason.encode!(entry))["raw_total"] == -1
    assert :ok == RollLog.acknowledge(log, [entry])
    assert RollLog.pending(log) == []
    RollLog.stop(rec)
  end

  test "a recorder already running before a code update can buffer a tool" do
    {:ok, rec} = RollLog.start()
    Agent.update(rec, &Map.delete(&1, :deferred))
    legacy = struct(RollLog, base: always(3), recorder: rec) |> Map.delete(:execution)
    log = RollLog.for_tool(legacy, make_ref())
    {roller, closer} = RollLog.open(log, nil, "Mara", :spell, "magia")
    roller.(4)
    entry = RollLog.close(closer, total: 3)
    assert RollLog.pending(log) == [entry]
    assert :ok == RollLog.acknowledge(log, [entry])
    assert RollLog.pending(log) == []
    RollLog.stop(rec)
  end

  test "tool executions buffer independently and acknowledge only committed groups" do
    parent = self()
    {:ok, rec} = RollLog.start(on_close: &send(parent, {:published, &1}))
    log = %RollLog{base: always(4), recorder: rec}
    first = RollLog.for_tool(log, make_ref())
    second = RollLog.for_tool(log, make_ref())

    {r1, c1} = RollLog.open(first, nil, "Mara", :damage, "primer efecto")
    {r2, c2} = RollLog.open(second, nil, "Lyra", :save, "salvación paralela")
    {r3, c3} = RollLog.open(log, nil, "Vex", :roll, "tirada independiente")
    r1.(4)
    r2.(20)
    r3.(6)
    entry1 = RollLog.close(c1, total: 4)
    entry2 = RollLog.close(c2, total: 4)
    entry3 = RollLog.close(c3, total: 4)
    assert_receive {:published, ^entry3}
    refute_receive {:published, _}, 10
    assert RollLog.pending(first) == [entry1]
    assert RollLog.pending(second) == [entry2]

    {r4, c4} = RollLog.open(first, nil, "Mara", :damage, "segundo efecto")
    r4.(4)
    entry4 = RollLog.close(c4, total: 4)
    assert :ok == RollLog.acknowledge(first, [entry1])
    assert RollLog.pending(first) == [entry4]
    assert RollLog.pending(second) == [entry2]
    assert :ok == RollLog.acknowledge(first, [entry4])
    assert RollLog.pending(first) == []
    assert {:ok, _} = Jason.encode(RollLog.entries(rec))
    RollLog.stop(rec)
  end

  test "with_hp_changes marks the last roll with every HP the tool changed" do
    world = fn hps ->
      %{characters: Map.new(hps, fn {n, hp} -> {n, %{hp: hp, max_hp: 10}} end)}
    end

    before = world.([{"Bran", 10}, {"Goblin", 7}, {"Aina", 9}])
    after_ = world.([{"Bran", 4}, {"Goblin", 0}, {"Aina", 9}])
    entries = [%{kind: :attack}, %{kind: :damage}]

    assert [%{kind: :attack} = first, %{hp: [["Bran", 4, 10], ["Goblin", 0, 10]]}] =
             RollLog.with_hp_changes(entries, before, after_)

    refute Map.has_key?(first, :hp)
    assert RollLog.with_hp_changes(entries, before, before) == entries
    assert RollLog.with_hp_changes(entries, nil, after_) == entries
    assert RollLog.with_hp_changes([], before, after_) == []
  end
end
