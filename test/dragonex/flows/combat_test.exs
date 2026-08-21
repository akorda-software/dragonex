defmodule Dragonex.Flows.CombatTest do
  @moduledoc """
  Flow 3 — combat, initiative, damage and death.

  Validates the combat loop end-to-end against the Session: Initiative policy
  drives turn order; an attacker's `attack`/`spawn_character` tools mutate the
  shared world via SharedState; HP drops track across participants; a character
  reaching 0 hp is dead.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.World
  alias ExAgent.Server, as: S
  alias ExAgent.Session, as: Sess

  # Fighter & goblin both use the game tools. We script them to act deterministically.
  defp fighter(script) do
    start_supervised_dm("fighter", "You are a brave fighter.", script)
  end

  test "initiative order is respected across a combat round" do
    # Order by DEX: rogue (fast) before goblin (slow).
    game =
      start_session(
        policy: {:initiative, order: ["rogue", "goblin"]},
        participants: [p("rogue"), p("goblin")]
      )

    assert {:ok, "rogue"} = Sess.start(game)
    assert {:ok, _, "goblin"} = Sess.take_turn(game, "rogue", fn w -> {:ok, w} end)
    assert {:ok, _, "rogue"} = Sess.take_turn(game, "goblin", fn w -> {:ok, w} end)
  end

  test "an attack reduces the target's HP, tracked in the shared world" do
    fighter =
      fighter([
        # Spawn the goblin (7 hp), then hit it for 3.
        tool_calls([call("spawn_character", %{"name" => "goblin", "hp" => 7})]),
        tool_calls([call("attack", %{"target" => "goblin", "damage" => 3})]),
        text("I hit the goblin!")
      ])

    game =
      start_session(
        world: World.new(),
        policy: :round_robin,
        participants: [p("fighter", :agent, fighter)]
      )

    assert {:ok, "fighter"} = Sess.start(game)
    :ok = take_turn(game, "fighter", fighter, fixed_roller(10))

    world = Sess.read_state(game)
    assert world.characters["goblin"].hp == 4
    assert world.characters["goblin"].max_hp == 7
  end

  test "damage floors at 0 and a character is dead at 0 hp" do
    game =
      start_session(
        world:
          World.new(
            characters: %{
              "goblin" =>
                Dragonex.Character.new(
                  name: "goblin",
                  class: "monster",
                  hp: 2,
                  max_hp: 7,
                  side: "enemy"
                )
            }
          ),
        policy: :round_robin,
        participants: [p("fighter")]
      )

    assert {:ok, "fighter"} = Sess.start(game)

    # fighter overkills the goblin (5 damage into 2 hp).
    assert {:ok, _, _} =
             Sess.take_turn(game, "fighter", fn w ->
               {:ok, elem(World.apply_damage("goblin", 5).(w), 1)}
             end)

    world = Sess.read_state(game)
    assert world.characters["goblin"].hp == 0
    assert World.down?(world, "goblin")
  end

  test "attacking an unknown target returns a clean error (no crash)" do
    fighter =
      fighter([tool_calls([call("attack", %{"target" => "ghost", "damage" => 1})]), text("miss")])

    game = start_session(policy: :round_robin, participants: [p("fighter", :agent, fighter)])
    assert {:ok, "fighter"} = Sess.start(game)
    :ok = take_turn(game, "fighter", fighter, fixed_roller(1))

    # The world has no "ghost"; the damage change errored, but the run continued.
    refute Map.has_key?(Sess.read_state(game).characters, "ghost")
  end

  # Helper that starts a generic agent (not strictly the DM) with the game tools.
  defp start_supervised_dm(id, instructions, script) do
    agent =
      ExAgent.new(
        model: %ExAgent.Models.Test{script: script},
        instructions: instructions,
        tools: Dragonex.Tools.tools()
      )

    ExUnit.Callbacks.start_supervised!({S, agent: agent, agent_id: id})
  end
end
