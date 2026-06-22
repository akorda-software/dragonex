defmodule Dragones.Flows.NarrationTest do
  @moduledoc """
  Flow 1 — DM narration.

  Validates the core loop of the game: a DM agent (ExAgent.Server), on its turn
  in a Session, calls the `set_scene` tool which mutates the shared World via
  SharedState.propose_change. The Session is the single writer; the agent never
  touches the world directly.
  """

  use ExUnit.Case, async: true

  import Dragones.Test.Harness

  alias Dragones.World

  test "the DM's set_scene tool mutates the world during its turn" do
    dm =
      start_dm(
        id: "dm-narr",
        script: [
          tool_calls([call("set_scene", %{"narration" => "a tense, torchlit tavern"})]),
          text("The goblin snarls across the room!")
        ]
      )

    game =
      start_session(
        policy: :round_robin,
        participants: [p("dm", :agent, dm)]
      )

    assert {:ok, "dm"} = ExAgent.Session.start(game)

    # The DM's turn: its tool reads ctx.deps.state (SharedState) + roller.
    take_turn(game, "dm", dm, fixed_roller(10))

    world = ExAgent.Session.read_state(game)
    assert world.scene == "a tense, torchlit tavern"
    assert {"dm", "scene: a tense, torchlit tavern"} in world.log
  end

  test "a tool that proposes a change outside the turn is refused" do
    # Validates the single-writer invariant from the DM's side: SharedState only
    # applies a change if it's THIS participant's turn.
    dm =
      start_dm(
        id: "dm-narr2",
        script: [text("idle")]
      )

    game =
      start_session(
        policy: :round_robin,
        participants: [p("dm", :agent, dm), p("other")]
      )

    assert {:ok, "dm"} = ExAgent.Session.start(game)
    # Advance past dm so it's no longer current.
    assert {:ok, _, _} = ExAgent.Session.take_turn(game, "dm", fn w -> {:ok, w} end)

    # "other" is current now; a change proposed as "dm" must be refused.
    handle = ExAgent.Session.SharedState.new(game, "dm")

    assert {:error, :not_your_turn} =
             ExAgent.Session.SharedState.propose_change(handle, World.set_scene("nope"))

    # The world is unchanged.
    refute ExAgent.Session.read_state(game).scene == "nope"
  end

  test "the DM can narrate (append to log) and advance the round" do
    dm =
      start_dm(
        id: "dm-narr3",
        script: [
          tool_calls([call("next_round", %{})]),
          text("A new round begins.")
        ]
      )

    game = start_session(policy: :round_robin, participants: [p("dm", :agent, dm)])
    assert {:ok, "dm"} = ExAgent.Session.start(game)

    take_turn(game, "dm", dm, fixed_roller(1))

    assert ExAgent.Session.read_state(game).round == 2
  end
end
