defmodule Dragonex.GameForcedInitiativeTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, History, Monsters}
  alias Dragonex.Game.Combat
  alias ExAgent.{Models.Test, Session}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game(enemies \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "Automatic initiative dice",
        roster: [{Archetypes.fighter(), :human} | enemies]
      )

    game
  end

  defp tracked_roller do
    counter = start_supervised!({Agent, fn -> {[20, 10, 2], []} end})

    roller = fn sides ->
      Agent.get_and_update(counter, fn
        {[value | rest], calls} -> {value, {rest, calls ++ [{sides, value}]}}
        {[], calls} -> {1, {[], calls ++ [{sides, 1}]}}
      end)
    end

    {roller, counter}
  end

  defp spawn do
    tool_calls([
      call("spawn_monster", %{"kind" => "goblin", "name" => "g1"}),
      call("spawn_monster", %{"kind" => "goblin", "name" => "g2"})
    ])
  end

  defp waiting(pid),
    do: Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)

  for opening_roll <- [1, 20] do
    test "a live enemy attack before initiative is rejected before opening d20 #{opening_roll}" do
      {:ok, game} =
        Games.create_game(
          title: "Initiative before hostile attacks",
          roster: [{%{Archetypes.fighter() | dex: 20}, :human}]
        )

      counter = start_supervised!({Agent, fn -> [] end})

      roller = fn sides ->
        Agent.update(counter, &(&1 ++ [sides]))
        if sides == 20, do: unquote(opening_roll), else: 1
      end

      script = [
        tool_calls([call("spawn_monster", %{"kind" => "goblin", "name" => "Goblin"})]),
        tool_calls([
          call("make_attack", %{
            "attacker" => "Goblin",
            "target" => "Thane",
            "weapon" => "scimitar",
            "mode" => "normal"
          })
        ]),
        tool_calls([call("roll_initiative", %{})]),
        narration("Thane, el goblin levanta la cimitarra; actúas primero.")
      ]

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game, {game.id, [model: %Test{script: script}, roller: roller]}}
        )

      assert :ok == waiting(pid)
      assert Agent.get(counter, & &1) == [20, 20]
      world = Game.world(pid)
      assert world.phase == :combat
      assert world.initiative_order == ["Thane", "Goblin"]
      assert world.current_combatant == "Thane"
      assert world.characters["Thane"].hp == 12
      assert world.characters["Goblin"].hp == 7
      assert Games.load_world(Games.get_game(game.id)) == world
      events = Games.list_events(game.id)
      dice = Enum.filter(events, &(&1.type == :dice))
      assert length(dice) == 2
      assert Enum.all?(dice, &(&1.payload["kind"] == "initiative"))
      refute Enum.any?(dice, &(&1.payload["timing"] == "forced_initiative"))
      refute Enum.any?(events, &String.contains?(&1.payload["note"] || "", "el turno falló"))
    end
  end

  for route <- [:ok, :error] do
    test "automatic initiative after a #{route} actor publishes factual dice exactly once" do
      game = game()
      {roller, counter} = tracked_roller()

      finish =
        if unquote(route) == :ok,
          do: narration("Thane, dos goblins cierran el paso."),
          else: fn -> raise "failure after committed spawn" end

      Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game, {game.id, [model: %Test{script: [spawn(), finish]}, roller: roller]}}
        )

      assert :ok == waiting(pid)
      world = Game.world(pid)
      assert world.phase == :combat
      assert world.initiative_order == ["Thane", "g1", "g2"]
      assert world.current_combatant == "Thane"
      assert world.acted_this_round == MapSet.new()
      assert world.characters["Thane"].hp == 12
      assert Games.load_world(Games.get_game(game.id)) == world
      assert Agent.get(counter, &elem(&1, 1)) == [{20, 20}, {20, 10}, {20, 2}]
      events = Games.list_events(game.id)

      speech =
        Enum.filter(
          events,
          &(&1.type == :narration and &1.actor == "dm" and &1.payload["turn_id"] != nil)
        )

      if unquote(route) == :ok do
        assert [
                 %{
                   payload: %{"text" => "Thane, dos goblins cierran el paso.", "complete" => true}
                 }
               ] = speech
      else
        refute Enum.any?(speech, &(&1.payload["complete"] == true))
      end

      dice = Enum.filter(events, &(&1.type == :dice))
      assert Enum.map(dice, & &1.payload["who"]) == ["Thane", "g1", "g2"]
      assert Enum.map(dice, & &1.payload["total"]) == [21, 12, 4]
      assert Enum.map(dice, & &1.payload["dice"]) == [[[20, 20]], [[20, 10]], [[20, 2]]]

      for name <- ["Thane", "g1", "g2"] do
        assert_receive {:dice_group, id, %{kind: :initiative, who: ^name}}
        assert id == game.id
      end

      refute_receive {:dice_group, _, _}
      assert Enum.all?(dice, &(&1.payload["timing"] == "forced_initiative"))
      context = inspect(History.from_events(events), limit: :infinity)
      for name <- ["Thane", "g1", "g2"], do: assert(context =~ name)
      assert context =~ "tirada de iniciativa"
      assert context =~ "d20:20"

      assert Enum.count(
               events,
               &(&1.payload["note"] ==
                   "⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente.")
             ) == 1
    end
  end

  test "explicit initiative records its dice without a second automatic roll" do
    game = game()
    {roller, counter} = tracked_roller()

    script = [
      spawn(),
      tool_calls([call("roll_initiative", %{})]),
      narration("Thane, los goblins cierran el paso.")
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: script}, roller: roller]}}
      )

    assert :ok == waiting(pid)
    assert Agent.get(counter, &elem(&1, 1)) == [{20, 20}, {20, 10}, {20, 2}]
    events = Games.list_events(game.id)
    dice = Enum.filter(events, &(&1.type == :dice))
    assert length(dice) == 3
    refute Enum.any?(dice, &(&1.payload["timing"] == "forced_initiative"))

    refute Enum.any?(
             events,
             &(&1.payload["note"] ==
                 "⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente.")
           )
  end

  test "preexisting enemies without new hostiles do not start combat or generate dice" do
    game = game([{Monsters.goblin(name: "g1"), :ai}])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("Thane, el goblin espera una respuesta.")]},
            roller: fn _ -> flunk("no initiative without a new hostile") end
          ]}}
      )

    assert :ok == waiting(pid)
    assert Game.world(pid).phase == :exploration
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
  end

  test "an unavailable session writer cannot publish uncommitted initiative dice" do
    game = game([{Monsters.goblin(name: "g1"), :ai}])
    world = Games.load_world(Games.get_game(game.id))

    session =
      start_supervised!(
        {Session, shared_state: world, participants: [p("dm", :other), p("Thane", :human)]}
      )

    state = %Game{
      game_id: game.id,
      session: session,
      roller: fn _ -> flunk("do not roll without an admitted writer") end
    }

    state = Combat.maybe_force_combat(state, MapSet.new())
    assert Session.read_state(state.session) == world
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
  end
end
