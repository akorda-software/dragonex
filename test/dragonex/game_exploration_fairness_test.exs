defmodule Dragonex.GameExplorationFairnessTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.Game.Beats
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game(opts \\ []) do
    roster =
      Keyword.get(opts, :roster, [
        {Archetypes.fighter(), :human},
        {Archetypes.wizard(), :ai},
        {Archetypes.rogue(), :ai}
      ])

    {:ok, game} =
      Games.create_game(
        title: "Equidad junto a la ventana",
        scene: "Una sala tranquila.",
        roster: roster
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, Keyword.get(opts, :current), world.round, :paused)
    {game, world}
  end

  defp turnmaster(targets) do
    counter = start_supervised!({Agent, fn -> [] end})

    script =
      for target <- targets,
          step <- [
            fn messages, _params ->
              Agent.update(counter, &(&1 ++ [inspect(messages, limit: :infinity)]))
              tool_calls([call("give_turn_to", %{"participant" => target})])
            end,
            text("listo")
          ],
          do: step

    {%Test{script: script}, counter}
  end

  defp boot(game, tm) do
    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: List.duplicate(narration("La luz permanece sobre la mesa."), 12)},
            turnmaster_model: tm
          ]}}
      )

    state = :sys.get_state(pid)

    for {name, server} <- state.pc_agents do
      assert :ok ==
               Server.set_model(server, %Test{
                 script: List.duplicate(narration("—Observo la ventana."), 8)
               })

      assert is_binary(name)
    end

    pid
  end

  defp wait(pid, name) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == name), 5_000)
  end

  defp first_decision(pid) do
    wait(pid, "Thane")
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Observo la mesa sin moverme.")
  end

  defp actors(game_id) do
    game_id |> Games.list_events() |> Enum.filter(&(&1.type == :turn)) |> Enum.map(& &1.actor)
  end

  defp past_turn(game, world, actor) do
    turn_id = "past-#{actor}"
    Beats.append_turn_marker(game.id, actor, turn_id, world)

    {:ok, _} =
      Games.append_event(game.id, :narration, actor, "all", %{
        text: "—Observo la mesa.",
        turn_id: turn_id,
        phase: world.phase,
        round: world.round
      })
  end

  test "a second valid Lyra decision after the DM cannot repeat her before a human" do
    {game, before} = game()
    {tm, counter} = turnmaster(["Lyra", "Lyra", "Thane"])
    pid = boot(game, tm)
    assert :ok == Game.resume(pid)
    first_decision(pid)
    wait(pid, "Thane")

    assert actors(game.id) == ["dm", "Thane", "dm", "Lyra", "dm"]
    assert length(Agent.get(counter, & &1)) == 2
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
  end

  test "different companions can act once and their completed cycle skips the next TM request" do
    {game, before} = game()
    {tm, counter} = turnmaster(["Lyra", "Vex", "Thane"])
    pid = boot(game, tm)
    assert :ok == Game.resume(pid)
    first_decision(pid)
    wait(pid, "Thane")

    assert actors(game.id) == ["dm", "Thane", "dm", "Lyra", "dm", "Vex", "dm"]
    requests = Agent.get(counter, & &1)
    assert length(requests) == 2
    assert List.last(requests) =~ "Personas que juegan: Thane"

    assert List.last(requests) =~
             "Compañeros que ya actuaron desde la última intervención humana: Lyra"

    assert Game.world(pid) == before
  end

  test "one companion returns to the human after the DM without another model handoff" do
    {game, before} = game(roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}])
    {tm, counter} = turnmaster(["Lyra", "Thane"])
    pid = boot(game, tm)
    assert :ok == Game.resume(pid)
    first_decision(pid)
    wait(pid, "Thane")

    assert actors(game.id) == ["dm", "Thane", "dm", "Lyra", "dm"]
    assert length(Agent.get(counter, & &1)) == 1
    assert Game.world(pid) == before
  end

  test "reopening the DM remembers prior PC turns despite hundreds of intervening events" do
    {game, before} = game(current: "dm")
    past_turn(game, before, "Thane")
    past_turn(game, before, "Lyra")

    for _ <- 1..220 do
      {:ok, _} =
        Games.append_event(game.id, :system, "system", "all", %{note: "La sala sigue tranquila."})
    end

    {tm, counter} = turnmaster(["Lyra", "Thane"])
    pid = boot(game, tm)
    assert :ok == Game.resume(pid)
    wait(pid, "Thane")

    assert actors(game.id) == ["Thane", "Lyra", "dm"]
    assert length(Agent.get(counter, & &1)) == 1
    assert Game.world(pid) == before
  end

  test "a completed AI cycle hands to the human who has waited longer and survives pause reload" do
    nera = %{Archetypes.fighter() | name: "Nera"}

    {game, before} =
      game(
        current: "dm",
        roster: [
          {Archetypes.fighter(), :human},
          {nera, :human},
          {Archetypes.wizard(), :ai}
        ]
      )

    past_turn(game, before, "Thane")
    past_turn(game, before, "Lyra")
    {tm, counter} = turnmaster(["Lyra", "Thane", "Nera"])
    pid = boot(game, tm)
    assert :ok == Game.resume(pid)
    wait(pid, "Nera")

    assert Agent.get(counter, & &1) == []
    assert actors(game.id) == ["Thane", "Lyra", "dm"]
    assert Game.world(pid) == before
    assert :ok == Game.pause(pid)
    assert :ok == stop_supervised({Game, game.id})
    reopened = boot(game, tm)
    assert Game.snapshot(reopened).status == :paused
    assert Game.snapshot(reopened).current == "Nera"
    assert :ok == Game.resume(reopened)
    wait(reopened, "Nera")
    assert Agent.get(counter, & &1) == []
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "a mute TM after one AI turn returns to the human instead of following a stale cursor" do
    {game, before} = game()
    {tm, counter} = turnmaster(["Lyra"])

    observe_mute = fn _messages, _params ->
      Agent.update(counter, &(&1 ++ ["mute"]))
      "(no decision)"
    end

    pid = boot(game, %{tm | script: tm.script ++ [observe_mute]})
    assert :ok == Game.resume(pid)
    first_decision(pid)
    wait(pid, "Thane")
    assert actors(game.id) == ["dm", "Thane", "dm", "Lyra", "dm"]
    assert length(Agent.get(counter, & &1)) == 2
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "a queued human declaration still outranks the person due after the AI cycle" do
    nera = %{Archetypes.fighter() | name: "Nera"}

    {game, before} =
      game(
        current: "dm",
        roster: [
          {Archetypes.fighter(), :human},
          {nera, :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    for name <- ["Nera", "Lyra", "Vex"], do: past_turn(game, before, name)
    {tm, _counter} = turnmaster(["Lyra", "Thane"])
    pid = boot(game, tm)
    assert {:ok, :queued} = Game.declare(pid, "Nera", "Miro la mesa sin salir de la sala.")
    assert :ok == Game.resume(pid)
    wait(pid, "Thane")
    assert actors(game.id) == ["Nera", "Lyra", "Vex", "dm", "Nera", "dm"]
    assert Game.snapshot(pid).intents == %{}
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
