defmodule Dragonex.GameActorFailureTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Archetypes, Game, Games, Monsters, World}
  alias Dragonex.Game.{Beat, Settlement}
  alias Dragonex.TurnPolicy.WorldDriven
  alias ExAgent.Session

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp roller(20), do: 15
  defp roller(_), do: 1

  defp state do
    {:ok, game} =
      Games.create_game(
        title: "Partial actor failure",
        roster: [
          {Archetypes.fighter(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ],
        initiative: ["g1", "g2", "Thane"]
      )

    world = Games.load_world(Games.get_game(game.id))
    {:ok, world} = World.set_current_combatant("g1").(world)

    session =
      start_supervised!(
        {Session,
         shared_state: world,
         policy: {WorldDriven, dm: "dm"},
         participants: [p("dm", :other), p("Thane", :human)]}
      )

    assert {:ok, "dm"} = Session.start(session)

    %Game{
      game_id: game.id,
      session: session,
      roller: &roller/1,
      status: :paused,
      busy: beat("dm"),
      participants: %{"dm" => %{kind: :other}, "Thane" => %{kind: :human}}
    }
  end

  defp beat(actor, mini? \\ false) do
    %Beat{
      participant: actor,
      phase: :combat,
      turn_id: "failed-#{actor}",
      enemies_before: MapSet.new(["g1", "g2"]),
      mini_turn: mini?
    }
  end

  defp fail(state), do: Settlement.handle_beat_result(state, {:error, {:crashed, :actor_failed}})

  test "a committed attack followed by an off-turn error spends only that monster's turn" do
    state = state()
    world = Session.read_state(state.session)
    {:ok, _, change} = Actions.attack(world, "g1", "Thane", "scimitar", &roller/1)
    assert {:ok, _} = Session.update_state(state.session, "dm", change)
    committed = Session.read_state(state.session)

    assert {:error, _} =
             Actions.attack(committed, "g2", "Thane", "scimitar", fn _ ->
               flunk("an off-turn monster must not roll")
             end)

    state = fail(state)
    after_first = Session.read_state(state.session)
    assert after_first.characters["Thane"].hp == committed.characters["Thane"].hp
    assert after_first.turn_state["g1"]["action"] == true
    assert after_first.current_combatant == "g2"
    assert after_first.acted_this_round == MapSet.new(["g1"])

    state = fail(%{state | busy: beat("dm")})
    after_second = Session.read_state(state.session)
    assert after_second.current_combatant == "Thane"
    assert after_second.acted_this_round == MapSet.new(["g1", "g2"])
    assert after_second.round == 1
    assert Games.load_world(Games.get_game(state.game_id)) == after_second
  end

  test "the last failed main turn completes the round and refreshes the next monster" do
    state = state()

    for name <- ["g1", "g2"] do
      assert {:ok, _} = Session.update_state(state.session, "dm", World.mark_acted(name))
    end

    assert {:ok, "Thane"} = Session.handoff(state.session, "Thane")

    assert {:ok, _} =
             Session.update_state(state.session, "Thane", World.set_current_combatant("Thane"))

    state = fail(%{state | busy: beat("Thane")})
    world = Session.read_state(state.session)
    assert world.round == 2
    assert world.acted_this_round == MapSet.new()
    assert world.current_combatant == "g1"
    assert world.turn_state["g1"]["round"] == 2
    assert Games.load_world(Games.get_game(state.game_id)) == world
  end

  test "a failed mini-turn leaves the main turn ledger and round intact" do
    state = state()
    assert {:ok, _} = Session.update_state(state.session, "dm", World.mark_acted("Thane"))
    state = fail(%{state | busy: beat("dm", true)})
    world = Session.read_state(state.session)
    assert world.acted_this_round == MapSet.new(["Thane"])
    assert world.round == 1
  end

  test "real failing Game beats visit both monsters before waiting on the human" do
    {:ok, game} =
      Games.create_game(
        title: "Actor failure loop",
        roster: [
          {Archetypes.fighter(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ],
        initiative: ["g1", "g2", "Thane"]
      )

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %ExAgent.Models.Test{script: [fn -> raise "actor failed" end]},
            roller: &roller/1
          ]}}
      )

    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    world = Game.world(pid)
    assert world.current_combatant == "Thane"
    assert world.acted_this_round == MapSet.new(["g1", "g2"])
    assert world.characters["Thane"].hp == Archetypes.fighter().hp
    assert Games.load_world(Games.get_game(game.id)) == world
  end
end
