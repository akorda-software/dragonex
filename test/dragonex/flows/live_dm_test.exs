defmodule Dragonex.Flows.LiveDMTest do
  @moduledoc """
  Live smoke tests for the `Dragonex.DM` module itself: a real LLM, given only
  the system prompt + the world brief + the tool schemas, drives the rules.

  Opt-in (`:integration` tag). Run with:

      DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=... DRAGONEX_MODEL=... \
        mix test --include integration

  The key invariant under test: the DM does NOT invent outcomes — it calls the
  tools, which is detectable as the engine rolling dice.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  alias Dragonex.{Archetypes, Brief, DM, Monsters, TurnPolicy.WorldDriven, World}
  alias ExAgent.{Server, Session}
  alias ExAgent.Session.{Participant, SharedState}

  defp live_ready? do
    System.get_env("DRAGONEX_RUN_LIVE") not in ["", nil, "0", "false"] and
      System.get_env("OPENROUTER_API_KEY") not in ["", nil]
  end

  defp model, do: Dragonex.Models.dm()

  defp build(world, changes) do
    Enum.reduce(changes, world, fn change, w ->
      {:ok, nw} = change.(w)
      nw
    end)
  end

  @tag :integration
  test "a live DM starts combat by calling roll_initiative" do
    unless live_ready?(),
      do: flunk("set DRAGONEX_RUN_LIVE=1 and OPENROUTER_API_KEY to run this test")

    {:ok, dm} =
      Server.start_link(agent: DM.new(model()), agent_id: "dm-init-#{unique()}", pubsub: :local)

    world =
      build(World.new(), [
        World.add_character(Archetypes.fighter()),
        World.add_character(Monsters.goblin())
      ])

    {:ok, game} = session(world, dm)

    assert {:ok, "dm"} = Session.start(game)
    deps = %{state: SharedState.new(game, "dm"), roller: &Dragonex.Dice.roll/1}

    assert {:ok, %{usage: usage}} =
             Server.chat(
               dm,
               Brief.turn_prompt(
                 Session.read_state(game),
                 "dm",
                 "Begin the fight: roll initiative."
               ),
               deps: deps
             )

    assert (usage.input_tokens || 0) > 0
    assert Session.read_state(game).phase == :combat
    assert length(Session.read_state(game).initiative_order) == 2
  end

  @tag :integration
  test "a live DM resolves the goblin's attack THROUGH the tools (dice are rolled)" do
    unless live_ready?(),
      do: flunk("set DRAGONEX_RUN_LIVE=1 and OPENROUTER_API_KEY to run this test")

    {:ok, dm} =
      Server.start_link(agent: DM.new(model()), agent_id: "dm-atk-#{unique()}", pubsub: :local)

    world =
      build(World.new(), [
        World.add_character(Archetypes.fighter()),
        World.add_character(Monsters.goblin()),
        World.begin_combat(["goblin", "Thane"])
      ])

    {:ok, game} = session(world, dm)
    assert {:ok, "dm"} = Session.start(game)

    # Instrumented roller: every call is proof the engine ran a tool.
    {:ok, roll_log} = Agent.start_link(fn -> [] end)

    roller = fn sides ->
      v = :rand.uniform(sides)
      Agent.update(roll_log, fn logs -> [{sides, v} | logs] end)
      v
    end

    assert {:ok, _} =
             Server.chat(
               dm,
               Brief.turn_prompt(
                 Session.read_state(game),
                 "dm",
                 "Run the goblin's turn: it attacks Thane. Call the right tool, then narrate."
               ),
               deps: %{state: SharedState.new(game, "dm"), roller: roller}
             )

    rolls = Agent.get(roll_log, &Enum.reverse/1)
    # The DM did not invent the outcome: it called a tool, so the engine rolled.
    refute rolls == [], "the DM narrated without calling a tool (no dice rolled)"

    world_after = Session.read_state(game)
    thane = world_after.characters["Thane"]
    # Whatever hit/miss the dice produced, Thane's hp is a valid result of the rules.
    assert thane.hp >= 0 and thane.hp <= thane.max_hp
  end

  defp session(world, dm) do
    Session.start_link(
      shared_state: world,
      policy: {WorldDriven, dm: "dm"},
      participants: [Participant.new(id: "dm", kind: :agent, ref: dm)],
      session_id: "live-dm-#{unique()}"
    )
  end

  defp unique, do: :erlang.unique_integer([:positive])
end
