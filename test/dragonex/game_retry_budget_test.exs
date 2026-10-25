defmodule Dragonex.GameRetryBudgetTest.Model do
  @behaviour ExAgent.Model
  defstruct [:counter]

  @impl true
  def request(model, _messages, _settings, _params) do
    next =
      Agent.get_and_update(model.counter, fn %{responses: responses, calls: calls} ->
        case responses do
          [item | rest] -> {item, %{responses: rest, calls: calls + 1}}
          [] -> {{:error, :script_exhausted}, %{responses: [], calls: calls + 1}}
        end
      end)

    case next do
      {:error, _} = error -> error
      %ExAgent.Message.Response{} = response -> {:ok, response, model}
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
  def model_name(_), do: "retry-budget"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: ExAgent.Models.Test.profile(%ExAgent.Models.Test{})
end

defmodule Dragonex.GameRetryBudgetTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.GameRetryBudgetTest.Model

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

  defp transient,
    do: {:error, %ExAgent.RequestError{provider: :openrouter, reason: :http_error, status: 503}}

  defp truncated, do: ExAgent.Message.new_response([], finish_reason: :length)

  defp completed,
    do: Dragonex.Test.Harness.narration_response("Thane, ¿qué observas en el patio?")

  defp run(responses) do
    {:ok, game} =
      Games.create_game(
        title: "Presupuestos independientes por turno",
        roster: [{Archetypes.fighter(), :human}]
      )

    world = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    counter = start_supervised!({Agent, fn -> %{responses: responses, calls: 0} end})
    model = %Model{counter: counter}

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: model, roller: fn sides -> flunk("unexpected d#{sides}") end]}}
      )

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status in [:waiting, :paused]), 5_000)
    %{game: game, pid: pid, counter: counter, before: world}
  end

  test "a max_tokens retry cannot replenish an exhausted transient retry budget" do
    context = run([transient(), transient(), transient(), truncated(), transient(), completed()])
    assert Game.status(context.pid) == :paused
    assert %{calls: 5, responses: [_unused]} = Agent.get(context.counter, & &1)
    world = Game.world(context.pid)
    assert world.actor_checkpoint["pending_narration"] == true
    assert world.characters == context.before.characters
    assert world.elapsed_seconds == context.before.elapsed_seconds
    assert Games.load_world(Games.get_game(context.game.id)) == world
    events = Games.list_events(context.game.id)
    assert Enum.count(events, &(&1.payload["kind"] == "turn_retained")) == 1
    turn_id = world.actor_checkpoint["turn_id"]
    assert is_binary(turn_id)
    refute Enum.any?(events, &(&1.type == :narration and &1.payload["turn_id"] == turn_id))
    refute Enum.any?(events, &(&1.type == :dice))
  end

  test "a max_tokens retry preserves the transient retries still available" do
    context = run([transient(), truncated(), transient(), transient(), completed()])
    assert Game.status(context.pid) == :waiting
    assert Game.current(context.pid) == "Thane"
    assert %{calls: 5, responses: []} = Agent.get(context.counter, & &1)
    world = Game.world(context.pid)
    assert world.actor_checkpoint == nil
    assert world.characters == context.before.characters
    assert world.elapsed_seconds == context.before.elapsed_seconds
    assert Games.load_world(Games.get_game(context.game.id)) == world
    events = Games.list_events(context.game.id)

    assert [%{payload: %{"turn_id" => turn_id}}] =
             Enum.filter(events, &(&1.type == :turn and &1.actor == "dm"))

    assert is_binary(turn_id)

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["turn_id"] == turn_id)
           ) == 1

    refute Enum.any?(events, &(&1.payload["kind"] == "turn_retained" or &1.type == :dice))
  end
end
