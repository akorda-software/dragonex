defmodule Dragonex.Flows.MultiParticipantTest do
  @moduledoc """
  Flow 6 — a full round coordinated by SupervisorPolicy.

  The signature D&D flow: a DM (supervisor) goes between every actor —
  dm → fighter (bot) → dm → human → … The DM narrates and sets the scene; the
  bot acts; the human acts via the test driver (a LiveView would call
  take_turn). All of them mutate the same shared world through SharedState.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias ExAgent.Server, as: S
  alias ExAgent.Session, as: Sess

  # The DM: narrates a scene each of its turns. Two narration turns scripted.
  defp dm_agent do
    ExAgent.new(
      model: %ExAgent.Models.Test{
        script: [
          tool_calls([call("set_scene", %{"narration" => "torchlit tavern"})]),
          text("The goblin snarls!"),
          tool_calls([call("set_scene", %{"narration" => "chaos erupts"})]),
          text("The goblin reels!")
        ]
      },
      instructions: "You are the DM.",
      tools: Dragonex.Tools.tools()
    )
  end

  # The bot fighter: spawns the goblin and attacks.
  defp bot_agent do
    ExAgent.new(
      model: %ExAgent.Models.Test{
        script: [
          tool_calls([call("spawn_character", %{"name" => "goblin", "hp" => 7})]),
          tool_calls([call("attack", %{"target" => "goblin", "damage" => 3})]),
          text("I swing my sword!")
        ]
      },
      instructions: "You are a brave fighter.",
      tools: Dragonex.Tools.tools()
    )
  end

  test "dm → fighter → dm → human: each acts, the shared world accumulates" do
    dm = ExUnit.Callbacks.start_supervised!({S, agent: dm_agent(), agent_id: "mp-dm"})
    bot = ExUnit.Callbacks.start_supervised!({S, agent: bot_agent(), agent_id: "mp-bot"})

    game =
      start_session(
        world: Dragonex.World.new(),
        policy: {:supervisor, supervisor: "dm", workers: ["bot", "human"]},
        participants: [p("dm", :agent, dm), p("bot", :agent, bot), p("human", :human)]
      )

    assert {:ok, "dm"} = Sess.start(game)

    # dm → bot → dm → human
    assert :ok = take_turn(game, "dm", dm, fixed_roller(10))
    assert Sess.current(game) == "bot"

    assert :ok = take_turn(game, "bot", bot, fixed_roller(10))
    assert Sess.current(game) == "dm"

    assert :ok = take_turn(game, "dm", dm, fixed_roller(10))
    assert Sess.current(game) == "human"

    # The human acts directly through the Session (a LiveView would do this).
    assert {:ok, _, _} =
             Sess.take_turn(game, "human", fn %Dragonex.World{} = w ->
               {:ok, %Dragonex.World{w | log: [{"human", "I cast firebolt for 4!"} | w.log]}}
             end)

    world = Sess.read_state(game)
    # DM set two scenes.
    assert {"dm", "scene: chaos erupts"} in world.log
    # Bot spawned + damaged the goblin (7 → 4).
    assert world.characters["goblin"].hp == 4
    # Human's action landed.
    assert {"human", "I cast firebolt for 4!"} in world.log
  end
end
