defmodule Dragonex.GameReactionRetryTest.Model do
  @behaviour ExAgent.Model
  defstruct [:counter, :fault]

  @impl true
  def request(model, _messages, _settings, _params) do
    attempt = Agent.get_and_update(model.counter, &{&1 + 1, &1 + 1})

    case {attempt, model.fault} do
      {1, :transient} ->
        {:error, %ExAgent.RequestError{provider: :openrouter, reason: :http_error, status: 503}}

      {1, :max_tokens} ->
        {:ok, ExAgent.Message.new_response([], finish_reason: :length), model}

      {1, :narration} ->
        calls = [
          Dragonex.Test.Harness.call("final_result", %{"text" => "La reacción termina."}),
          Dragonex.Test.Harness.call("roll_dice", %{"count" => 1, "sides" => 20})
        ]

        {:ok, ExAgent.Message.new_response(calls, finish_reason: :tool_calls), model}

      _ ->
        {:ok, Dragonex.Test.Harness.narration_response("La reacción termina."), model}
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:ok, response, updated} -> [Dragonex.Test.Harness.stream_response(response, updated)]
      {:error, reason} -> [{:error, reason}]
    end
  end

  @impl true
  def model_name(_), do: "reaction-retry"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: ExAgent.Models.Test.profile(%ExAgent.Models.Test{})
end

defmodule Dragonex.GameReactionRetryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Archetypes, Game, Games, Monsters, World}
  alias Dragonex.GameReactionRetryTest.Model
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    previous = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [10, 10, 10])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:dragonex, :transient_backoffs),
        else: Application.put_env(:dragonex, :transient_backoffs, previous)
    end)

    :ok
  end

  defp start_reaction(kind, fault) do
    {:ok, game} =
      Games.create_game(
        title: "Reacción interrumpida por el proveedor",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), if(kind == :ai, do: :ai, else: :human)},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ],
        initiative: ["g1", "Thane", "g2", "Lyra"]
      )

    world = Games.load_world(game)
    {:ok, world} = World.mark_acted("g1").(world)
    {:ok, world} = World.set_current_combatant("Thane").(world)
    {:ok, _, wind} = Actions.second_wind(world, "Thane", fn _ -> 1 end)
    {:ok, world} = wind.(world)
    budget = world.turn_state["Thane"]
    reactor = if kind == :monster, do: "g2", else: "Lyra"
    {:ok, world} = World.set_current_combatant(reactor, "reaction").(world)
    controller = World.controller_of(world, reactor)
    {:ok, _} = Games.save_state(game.id, world, controller, world.round, :paused)

    counter = start_supervised!({Agent, fn -> 0 end})
    model = %Model{counter: counter, fault: fault}

    opts = [
      model: model,
      roller: fn sides -> flunk("unexpected d#{sides}") end,
      turnmaster_model: %Test{
        script: [tool_calls([call("give_turn_to", %{"participant" => "Thane"})]), "Listo."]
      }
    ]

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, opts}})
    assert :ok == Game.resume(pid)

    if kind == :human do
      assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == controller), 5_000)
      assert {:ok, :resolving} == Game.declare(pid, controller, "Me interpongo sin atacar.")
    end

    %{
      game: game,
      pid: pid,
      budget: budget,
      counter: counter,
      controller: controller,
      world: world
    }
  end

  defp assert_returned(%{game: game, pid: pid, budget: budget, counter: counter} = context) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    world = Game.world(pid)
    assert world.phase == :combat
    assert world.round == 1
    assert world.current_combatant == "Thane"
    assert world.turn_owner == "Thane"
    assert world.turn_kind == "main"
    assert world.acted_this_round == MapSet.new(["g1"])
    assert world.turn_state["Thane"] == budget
    assert world.characters == context.world.characters
    assert world.spell_slots == context.world.spell_slots
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Agent.get(counter, & &1) == 2

    events = Games.list_events(game.id)

    assert [%{payload: %{"turn_id" => turn_id}}] =
             Enum.filter(events, &(&1.type == :turn and &1.actor == context.controller))

    assert is_binary(turn_id)

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == context.controller and
                 &1.payload["turn_id"] == turn_id)
           ) == 1

    refute Enum.any?(events, &(&1.type == :dice))
  end

  test "an AI reaction retried after a provider error does not consume its main slot" do
    start_reaction(:ai, :transient) |> assert_returned()
  end

  test "a human reaction retried after max_tokens preserves the unfinished main turn" do
    start_reaction(:human, :max_tokens) |> assert_returned()
  end

  test "a monster reaction retried after an invalid closure keeps its main slot" do
    start_reaction(:monster, :narration) |> assert_returned()
  end

  test "pausing and resuming a parked reaction retry retains its mini-turn" do
    Application.put_env(:dragonex, :transient_backoffs, [60_000])
    context = start_reaction(:ai, :transient)
    pid = context.pid
    assert :ok == Game.await(pid, &(&1.busy_stage == :retrying), 5_000)
    pending = :sys.get_state(pid).busy
    assert Game.world(pid).actor_checkpoint == nil
    assert :ok == Game.pause(pid)

    send(pid, {:retry_beat, pending.turn_id})
    assert :sys.get_state(pid).busy == pending
    assert Game.status(pid) == :paused
    assert Agent.get(context.counter, & &1) == 1

    assert :ok == Game.resume(pid)
    send(pid, {:retry_beat, pending.turn_id})
    assert_returned(context)
  end
end
