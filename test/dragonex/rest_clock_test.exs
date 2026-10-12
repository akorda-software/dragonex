defmodule Dragonex.RestClockTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, World, Codec}

  defp world(level \\ 1) do
    c = Character.new(name: "A", class: "fighter", level: level, hp: 1, max_hp: 50)
    World.new(characters: %{"A" => c})
  end

  defp short(w) do
    {:ok, _, f} = Actions.short_rest(w, "A", fn _ -> 4 end)
    {:ok, w} = f.(w)
    w
  end

  test "short rests spend finite hit dice, but can recover features without dice" do
    w = short(world())
    assert w.characters["A"].hp == 5
    w = w |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    w = short(w)
    assert w.characters["A"].hp == 5
    assert w.elapsed_seconds == 7200
  end

  test "a long rest returns at most half hit dice and is limited to once per day" do
    w = Enum.reduce(1..3, world(3), fn _, w -> short(w) end)
    {:ok, _, rest} = Actions.long_rest(w, "A")
    {:ok, w} = rest.(w)
    assert w.rest_state["A"]["hit_dice_used"] == 2
    assert {:error, _} = Actions.long_rest(w, "A")
    {:ok, w} = World.advance_time(86400).(w)
    assert {:ok, _, _} = Actions.long_rest(w, "A")
  end

  test "rest cannot be applied after combat has started" do
    w = world()
    {:ok, _, rest} = Actions.short_rest(w, "A", fn _ -> 4 end)
    {:ok, w} = World.begin_combat(["A"]).(w)
    assert {:error, _} = rest.(w)
  end

  test "concentration and rage expire through the same persisted world clock" do
    w = world()
    {:ok, w} = World.set_concentration("A", "bless").(w)
    w = w |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    {:ok, w} = World.advance_time(59).(w)
    assert w.characters["A"].concentrating == "bless"
    {:ok, w} = World.advance_time(1).(w)
    assert w.characters["A"].concentrating == nil
  end

  test "short rest resets Relentless Rage DC but preserves rage uses" do
    c =
      Character.new(
        name: "A",
        class: "barbarian",
        level: 11,
        hp: 10,
        max_hp: 50,
        relentless_rage_successes: 2,
        rage_uses_used: 2
      )

    w = World.new(characters: %{"A" => c}) |> short()
    assert w.characters["A"].relentless_rage_successes == 0
    assert w.characters["A"].rage_uses_used == 2
  end

  test "choose several hit dice or none; overspending rejects before rolling" do
    w = world(3)
    assert {:error, _} = Actions.short_rest(w, "A", fn _ -> flunk("overspend") end, nil, 4)
    {:ok, _, f} = Actions.short_rest(w, "A", fn _ -> 4 end, nil, 2)
    {:ok, w} = f.(w)
    assert w.characters["A"].hp == 9
    assert w.rest_state["A"]["hit_dice_used"] == 2
    {:ok, _, f} = Actions.short_rest(w, "A", fn _ -> flunk("zero dice") end, nil, 0)
    {:ok, w} = f.(w)
    assert w.characters["A"].hp == 9
  end

  test "party rests advance time once and recover every member atomically" do
    w = world()
    b = Character.new(name: "B", hp: 1, max_hp: 10)
    w = %{w | characters: Map.put(w.characters, "B", b)}
    {:ok, _, rest} = Actions.rest_party(w, ["A", "B"], "long", fn _ -> 4 end)
    {:ok, next} = rest.(w)
    assert next.elapsed_seconds == 28800
    assert next.characters["A"].hp == 50
    assert next.characters["B"].hp == 10
    assert next.rest_state["A"]["last_long_rest_start"] == 0
    assert next.rest_state["B"]["last_long_rest_start"] == 0
    assert {:error, _} = Actions.rest_party(w, ["A", "missing"], "long", fn _ -> 4 end)
  end

  test "long rest clears temporary HP; short rest preserves them" do
    w = world()
    {:ok, w} = World.apply_temp_hp("A", 8).(w)
    w = short(w)
    assert w.characters["A"].temp_hp == 8
    {:ok, _, rest} = Actions.long_rest(w, "A")
    {:ok, w} = rest.(w)
    assert w.characters["A"].temp_hp == 0
  end

  test "ten combat rounds expire a one-minute effect across save/load" do
    w = world()
    {:ok, w} = World.set_concentration("A", "bless").(w)
    {:ok, w} = World.begin_combat(["A"]).(w)

    w =
      Enum.reduce(1..9, w, fn _, acc ->
        {:ok, n} = World.next_round().(acc)
        n
      end)

    assert w.characters["A"].concentrating == "bless"
    w = w |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    {:ok, w} = World.next_round().(w)
    assert w.elapsed_seconds == 60
    assert w.characters["A"].concentrating == nil
  end

  test "renewing the same spell starts a fresh duration; explicit conditions also expire" do
    w = world()
    {:ok, w} = World.set_concentration("A", "bless").(w)
    {:ok, w} = World.advance_time(50).(w)
    {:ok, w} = World.set_concentration("A", "bless").(w)
    {:ok, w} = World.apply_condition("A", "poisoned", 10).(w)
    {:ok, w} = World.advance_time(10).(w)
    assert w.characters["A"].concentrating == "bless"
    refute World.has_condition?(w, "A", "poisoned")
    {:ok, w} = World.advance_time(50).(w)
    assert w.characters["A"].concentrating == nil
  end

  test "rage and inspiration expire at their respective durations" do
    c = Character.new(name: "A", class: "barbarian", hp: 10, max_hp: 20)
    w = World.new(characters: %{"A" => c})
    {:ok, w} = World.start_rage("A").(w)
    {:ok, w} = World.set_inspired("A", true).(w)
    {:ok, w} = World.advance_time(60).(w)
    refute w.characters["A"].raging
    assert w.characters["A"].inspired
    {:ok, w} = World.advance_time(540).(w)
    refute w.characters["A"].inspired
  end

  test "legacy JSON starts with finite effect durations and full untracked hit dice" do
    w = world()
    {:ok, w} = World.set_concentration("A", "bless").(w)

    encoded =
      Codec.encode(w)
      |> Map.drop([
        "effect_expiries",
        "rest_state",
        "elapsed_seconds",
        "turn_state",
        "turn_kind",
        "turn_owner"
      ])

    restored = Codec.decode(encoded)
    assert Dragonex.Rest.remaining(restored, "A") == 1
    {:ok, restored} = World.advance_time(60).(restored)
    assert restored.characters["A"].concentrating == nil
  end

  test "timed temporary HP expire, but their old timer cannot erase a stronger replacement" do
    {:ok, w} = World.apply_temp_hp_for("A", 8, 60).(world())
    {:ok, expired} = World.advance_time(60).(w)
    assert expired.characters["A"].temp_hp == 0
    {:ok, replaced} = World.apply_temp_hp("A", 12).(w)
    {:ok, replaced} = World.advance_time(60).(replaced)
    assert replaced.characters["A"].temp_hp == 12
  end
end
