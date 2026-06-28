defmodule Dragones.RollLogTest do
  @moduledoc """
  The per-beat roll recorder: each die roll is captured in a structured group
  with who/why/dice/total/against/outcome, JSON-safe for the timeline.
  """

  use ExUnit.Case, async: true

  alias Dragones.RollLog

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
end
