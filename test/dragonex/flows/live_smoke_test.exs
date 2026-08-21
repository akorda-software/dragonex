defmodule Dragonex.Flows.LiveSmokeTest do
  @moduledoc """
  Flow 10 — live DM smoke test.

  Optional / opt-in: excluded by default (`:integration` tag). Run with:

      DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=... mix test --include integration

  A DM agent (real model via OpenRouter) drives the game tools against a live
  Session: it must narrate AND call `set_scene` to mutate the world. This is the
  real "does the prompt + tools + loop cohere with an actual LLM" check that the
  offline TestModel cannot give.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  alias Dragonex.Tools
  alias Dragonex.World
  alias ExAgent.{Models, Server, Session}
  alias ExAgent.Session.{Participant, SharedState}

  # Opt-in is via the :integration tag (excluded by default). The env gate is a
  # clear-fail safety net rather than a silent skip — ExUnit 1.20 doesn't support
  # {:skip, _} from setup callbacks.
  defp live_ready? do
    System.get_env("DRAGONEX_RUN_LIVE") not in ["", nil, "0", "false"] and
      System.get_env("OPENROUTER_API_KEY") not in ["", nil]
  end

  @tag :integration
  test "a live DM narrates and sets the scene via the tool" do
    unless live_ready?(),
      do: flunk("set DRAGONEX_RUN_LIVE=1 and OPENROUTER_API_KEY to run this test")

    model =
      Models.OpenRouter.new(
        model: System.get_env("DRAGONEX_MODEL", "z-ai/glm-4.7-flash"),
        app_title: "dragonex smoke test"
      )

    agent =
      ExAgent.new(
        model: model,
        instructions: """
        You are the Dungeon Master of a short scene.
        ALWAYS call the `set_scene` tool once with your narration before answering.
        Be vivid but brief (2 sentences).
        """,
        tools: Tools.tools(),
        model_settings: [max_tokens: 1024, temperature: 0]
      )

    {:ok, dm} =
      Server.start_link(
        agent: agent,
        agent_id: "live-dm-#{:erlang.unique_integer([:positive])}",
        pubsub: :local
      )

    {:ok, game} =
      Session.start_link(
        shared_state: World.new(),
        policy: :round_robin,
        participants: [Participant.new(id: "dm", kind: :agent, ref: dm)],
        session_id: "live-game"
      )

    assert {:ok, "dm"} = Session.start(game)

    deps = %{state: SharedState.new(game, "dm"), roller: &Dragonex.Dice.roll/1}

    assert {:ok, %{usage: usage}} =
             Server.chat(dm, "Set the opening scene: a tavern at dusk.", deps: deps)

    # Real usage reported.
    assert (usage.input_tokens || 0) > 0

    # The DM called set_scene, so the world's scene + log actually changed.
    world = Session.read_state(game)
    refute world.scene == World.new().scene
    assert Enum.any?(world.log, fn {actor, _} -> actor == "dm" end)

    Server.abort(dm)
  end
end
