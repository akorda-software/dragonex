# A model that fails the first N requests with a chosen `RequestError`, then
# returns `recovery` through final_result. The counter lives in an external Agent so
# it survives the Server not re-integrating the model after an error — important
# because `Dragonex.Game` only reuses the mutated model on success. Defined
# before the test module so its struct is in scope at compile time.
defmodule Dragonex.GameRetryTest.FlakyModel do
  @behaviour ExAgent.Model

  alias ExAgent.Message.Response

  defstruct [:counter, :error, :recovery]

  @impl true
  def request(%__MODULE__{counter: counter} = m, _messages, _settings, _params) do
    if dec(counter) do
      {:error, m.error}
    else
      {:ok, Dragonex.Test.Harness.narration_response(m.recovery), m}
    end
  end

  @impl true
  def request_stream(%__MODULE__{} = m, messages, settings, params) do
    case request(m, messages, settings, params) do
      {:error, error} ->
        [{:error, error}]

      {:ok, resp, updated} ->
        text = Response.text(resp)

        Stream.concat([
          Stream.map(word_chunks(text), fn c -> {:text_delta, c} end),
          [Dragonex.Test.Harness.stream_response(resp, updated)]
        ])
    end
  end

  defp word_chunks(text), do: String.split(text, ~r/(?<=\s)/, include_captures: true)

  # Returns true while failures remain (and decrements); false once exhausted.
  defp dec(counter) do
    Agent.get_and_update(counter, fn
      0 -> {false, 0}
      n -> {true, n - 1}
    end)
  end

  @impl true
  def model_name(_), do: "flaky"
  @impl true
  def system(_), do: "flaky"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
end

defmodule Dragonex.GameRetryTest do
  @moduledoc """
  Bug #1: transient provider errors (503 / rate limit / timeouts / connection
  drops) must be retried with backoff; a turn that still fails pauses (D228).
  A real DeepSeek outage used to chain 5+ fallbacks in a row; now each beat gets
  up to `@max_transient_retries` retries.

  Assertions are log-driven (`ExUnit.CaptureLog`) rather than counter-driven,
  because the DM and every AI PC share one model and the WorldDriven policy runs
  a DM scene-setting beat first — so the exact number of requests depends on how
  many beats fire before the human's :waiting turn. The log, by contrast,
  unambiguously shows whether retries happened and whether the soft fallback ran.
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Dragonex.{Archetypes, Games, Game, Monsters}
  alias Dragonex.GameRetryTest.FlakyModel
  alias ExAgent.RequestError

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    # Shrink backoff to milliseconds so retries resolve instantly instead of
    # sleeping through real seconds.
    prev = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [10, 10, 10])

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dragonex, :transient_backoffs)
        v -> Application.put_env(:dragonex, :transient_backoffs, v)
      end
    end)

    :ok
  end

  defp waiting_on(name),
    do: fn s -> s.status == :waiting and s.current == name end

  defp new_game do
    {:ok, game} =
      Games.create_game(
        title: "retry",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    game
  end

  defp flaky(fails, error, recovery) do
    {:ok, counter} = Agent.start_link(fn -> fails end)
    model = %FlakyModel{counter: counter, error: error, recovery: recovery}
    {counter, model}
  end

  # The recovery beat uses the same explicit narration output as production;
  # we care that the beat
  # completed and the turn advanced.
  @recovery "El goblin se reacomoda y gruñe, midiendo al enemigo."

  # Run the game until the human (Thane) is waiting, capturing all logger
  # output produced along the way. The beat log lines ("retry N/3", "el turno
  # falló") are how we tell retry-vs-fallback apart without fragile counters.
  defp run_until_thane_waits(game_id, model) do
    capture_log(fn ->
      pid =
        Dragonex.Test.GameFixture.start!({Game, {game_id, [model: model, roller: hit_roller()]}})

      assert :ok == Game.await(pid, waiting_on("Thane"), 8_000)
    end)
  end

  defp failed_turn?(log) do
    log =~ "el turno falló"
  end

  defp start_until_paused(game_id, model) do
    parent = self()

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game_id, [model: model, roller: hit_roller()]}}
          )

        assert :ok == Game.await(pid, &(&1.status == :paused), 8_000)
        send(parent, {:paused_game, pid})
      end)

    assert_received {:paused_game, pid}
    {pid, log}
  end

  defp run_until_paused(game_id, model), do: game_id |> start_until_paused(model) |> elem(1)

  defp retained_notes(game_id) do
    Games.list_events(game_id)
    |> Enum.filter(&(&1.type == :system and &1.payload["kind"] == "turn_retained"))
  end

  # The opening narration written by create_game has no turn_id.
  defp narrations(game_id),
    do:
      Enum.filter(Games.list_events(game_id), &(&1.type == :narration and &1.payload["turn_id"]))

  defp system_failure_events(game_id) do
    Games.list_events(game_id)
    |> Enum.filter(fn e ->
      e.type == :system and (e.payload["note"] || "") =~ "el turno falló"
    end)
  end

  test "a transient 503 is retried with backoff, then the beat completes" do
    game = new_game()

    {_counter, model} =
      flaky(
        2,
        %RequestError{
          provider: :openrouter,
          status: 503,
          reason: :http_error,
          body: "overloaded"
        },
        @recovery
      )

    log = run_until_thane_waits(game.id, model)

    # Two backoff retries fired for the 503...
    assert log =~ "retry 1/3"
    assert log =~ "retry 2/3"
    # ...and the beat recovered on the next attempt — no soft fallback.
    refute failed_turn?(log)
    assert system_failure_events(game.id) == []
  end

  test "a parked retry exposes its own stage and pause/resume cannot turn it into narration" do
    Application.put_env(:dragonex, :transient_backoffs, [60_000])

    {:ok, game} =
      Games.create_game(
        title: "Espera de reintento",
        scene: "El patio.",
        roster: [{Archetypes.fighter(), :human}]
      )

    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)

    {_counter, model} =
      flaky(1, %RequestError{provider: :openrouter, reason: :timeout}, "Thane, ¿qué haces?")

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(Map.get(&1, :busy_stage) == :retrying), 2_000)
    pending = :sys.get_state(pid).busy
    assert %Dragonex.Game.PendingRetry{} = pending
    assert Game.world(pid) == before
    events = Games.list_events(game.id)
    assert :ok = Game.pause(pid)
    assert Game.snapshot(pid).busy_stage == nil
    assert :ok = Game.resume(pid)
    assert Game.snapshot(pid).busy_stage == :retrying
    assert Games.list_events(game.id) == events
    send(pid, {:retry_beat, pending.turn_id})
    assert :ok = Game.await(pid, waiting_on("Thane"), 2_000)
    assert Game.snapshot(pid).busy_stage == nil
    assert :ok = Game.pause(pid)
  end

  test "a transient timeout is retried as well (transport-level error)" do
    game = new_game()

    {_counter, model} =
      flaky(
        1,
        %RequestError{provider: :openrouter, reason: :timeout, body: "connection timed out"},
        @recovery
      )

    log = run_until_thane_waits(game.id, model)

    assert log =~ "retry 1/3"
    refute failed_turn?(log)
    assert system_failure_events(game.id) == []
  end

  test "exhausting transient retries pauses the same turn instead of inventing prose" do
    game = new_game()

    # Fails forever: the 3-retry budget is exhausted on the first beat.
    {_counter, model} =
      flaky(
        99,
        %RequestError{
          provider: :openrouter,
          status: 503,
          reason: :http_error,
          body: "overloaded"
        },
        @recovery
      )

    log = run_until_paused(game.id, model)

    # All three retries fired before giving up, then the turn was retained.
    assert log =~ "retry 3/3"
    assert failed_turn?(log)
    assert system_failure_events(game.id) != []
    assert [note] = retained_notes(game.id)
    assert note.payload["note"] =~ "el proveedor no respondió tras varios intentos"
    assert narrations(game.id) == []
  end

  test "a non-transient 400 pauses immediately and resume reruns the same turn" do
    game = new_game()

    {_counter, model} =
      flaky(
        1,
        %RequestError{
          provider: :openrouter,
          status: 400,
          reason: :http_error,
          body: "bad request"
        },
        @recovery
      )

    {pid, log} = start_until_paused(game.id, model)

    # A 400 is a client error — retrying won't help, so NO backoff retry fires.
    refute log =~ "retry 1/3"
    assert [%{payload: %{"turn_id" => turn} = note}] = retained_notes(game.id)
    assert note["note"] =~ "el proveedor rechazó la petición"
    assert note["note"] =~ "Reanuda"
    assert narrations(game.id) == []

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, waiting_on("Thane"), 8_000)

    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :turn and &1.payload["turn_id"] == turn)) == 1
    assert Enum.any?(events, &(&1.type == :narration and &1.payload["turn_id"] == turn))
    refute Enum.any?(events, &(&1.payload["kind"] == "turn_skipped"))
  end

  test "a provider 'rate limit' body is treated as transient" do
    game = new_game()

    {_counter, model} =
      flaky(
        1,
        %RequestError{
          provider: :openrouter,
          status: 200,
          reason: :provider_error,
          body: "Rate limit exceeded, please try again"
        },
        @recovery
      )

    log = run_until_thane_waits(game.id, model)

    # The body's "rate"/"try again" markers make a :provider_error transient.
    assert log =~ "retry 1/3"
    refute failed_turn?(log)
  end

  test "a persistently failing provider pauses each turn once and skips it on a second failure" do
    # Two AI agents that auto-act: no human :waiting stops the loop.
    {:ok, game} =
      Games.create_game(
        title: "breaker",
        scene: "una sala",
        roster: [{Archetypes.fighter(), :ai}, {Monsters.goblin(), :ai}]
      )

    # Always fails with a non-transient 400.
    {_counter, model} =
      flaky(
        99,
        %RequestError{
          provider: :openrouter,
          status: 400,
          reason: :http_error,
          body: "bad request"
        },
        @recovery
      )

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: hit_roller()]}})

    assert :ok == Game.await(pid, &(&1.status == :paused), 15_000)
    assert [%{payload: %{"turn_id" => first}}] = retained_notes(game.id)

    # Resume reruns that turn; its second failure skips it, and the next
    # actor's first failure pauses the table again.
    assert :ok == Game.resume(pid)

    assert :ok ==
             Game.await(
               pid,
               fn s -> s.status == :paused and length(retained_notes(game.id)) == 2 end,
               15_000
             )

    events = Games.list_events(game.id)

    assert [%{payload: %{"turn_id" => ^first}}] =
             Enum.filter(events, &(&1.payload["kind"] == "turn_skipped"))

    assert narrations(game.id) == []
  end

  # d20 always 15 (a hit), every other die 1 (minimal damage) — combat-safe.
  defp hit_roller do
    fn
      20 -> 15
      _n -> 1
    end
  end
end
