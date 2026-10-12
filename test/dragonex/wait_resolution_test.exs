defmodule Dragonex.WaitResolutionTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Codec, World}
  alias Dragonex.Game.WaitResolution

  @request %{seconds: 1200, clock_before: 32400, source_turn_id: "wait-one"}

  test "a partial wait has a durable receipt after the actor checkpoint is gone" do
    {:ok, before} = World.advance_time(32400).(World.new())
    {:ok, world} = World.resolve_wait("wait-one", 1200, 60).(before)
    assert world.elapsed_seconds == 32460
    assert world.actor_checkpoint == nil
    assert world.wait_resolution["elapsed_seconds"] == 60
    assert WaitResolution.resolved?(world, @request, "another-dm-turn")
    restored = world |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert restored == world
    assert WaitResolution.resolved?(restored, @request, "after-restart")
    assert {:ok, ^restored} = World.resolve_wait("wait-one", 1200, 1200).(restored)
  end

  test "zero-time interruption survives roundtrip; a new declaration can consume the same duration" do
    {:ok, world} = World.resolve_wait("wait-one", 1200, 0).(World.new())
    assert world.elapsed_seconds == 0
    assert world.wait_resolution["clock_after"] == 0
    assert Codec.decode(Codec.encode(world)) == world
    assert {:ok, ^world} = World.resolve_wait("wait-one", 1200, 1200).(world)
    {:ok, next} = World.resolve_wait("wait-two", 1200, 1200).(world)
    assert next.elapsed_seconds == 1200
    assert next.wait_resolution["source_turn_id"] == "wait-two"
  end

  test "invalid sources, durations and combat cannot mutate the clock" do
    world = World.new()

    for {source, declared, elapsed} <- [
          {nil, 1200, 60},
          {"", 1200, 60},
          {"wait-one", 0, 0},
          {"wait-one", 1200, -1},
          {"wait-one", 1200, 1201},
          {"wait-one", 1200, "60"}
        ] do
      assert {:error, _} = World.resolve_wait(source, declared, elapsed).(world)
    end

    assert {:error, _} = World.resolve_wait("wait-one", 1200, 60).(%{world | phase: :combat})
    assert world.elapsed_seconds == 0
    assert world.wait_resolution == nil
  end

  test "legacy and malformed receipt data do not invent a completed interval" do
    encoded = Codec.encode(World.new())
    assert Codec.decode(Map.delete(encoded, "wait_resolution")).wait_resolution == nil

    assert Codec.decode(Map.put(encoded, "wait_resolution", %{"source_turn_id" => "wait-one"})).wait_resolution ==
             nil
  end
end
