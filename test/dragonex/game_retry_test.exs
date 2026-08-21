# A model that fails the first N requests with a chosen `RequestError`, then
# returns `recovery` (text). The failure counter lives in an external Agent so
# it survives the Server not re-integrating the model after an error — important
# because `Dragonex.Game` only reuses the mutated model on success. Defined
# before the test module so its struct is in scope at compile time.
defmodule Dragonex.GameRetryTest.FlakyModel do
  @behaviour ExAgent.Model

  alias ExAgent.Message, as: Msg
  alias ExAgent.Message.{Part, Response, Usage}

  defstruct [:counter, :error, :recovery]

  @impl true
  def request(%__MODULE__{counter: counter} = m, _messages, _settings, _params) do
    if dec(counter) do
      {:error, m.error}
    else
      {:ok, text_response(m.recovery), m}
    end
  end

  @impl true
  def request_stream(%__MODULE__{} = m, messages, settings, params) do
    case request(m, messages, settings, params) do
      {:error, error} ->
        [{:error, error}]

      {:ok, resp, _} ->
        text = Response.text(resp)

        Stream.concat([
          Stream.map(word_chunks(text), fn c -> {:text_delta, c} end),
          [{:response, resp}]
        ])
    end
  end

  defp word_chunks(text), do: String.split(text, ~r/(?<=\s)/, include_captures: true)

  defp text_response(text) do
    Msg.new_response([%Part.Text{content: text}],
      usage: %Usage{input_tokens: 1, output_tokens: 1},
      model_name: "flaky"
    )
  end

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
  def profile(_), do: %ExAgent.ModelProfile{}
end

defmodule Dragonex.GameRetryTest do
  @moduledoc """
  Bug #1: transient provider errors (503 / rate limit / timeouts / connection
  drops) must be retried with backoff before falling back to the soft narration.
  A real DeepSeek outage used to chain 5+ fallbacks in a row; now each beat gets
  up to `@max_transient_retries` retries.

  Assertions are log-driven (`ExUnit.CaptureLog`) rather than counter-driven,
  because the DM and every AI PC share one model and the WorldDriven policy runs
  a DM scene-setting beat first — so the exact number of requests depends on how
  many beats fire before the human's :waiting turn. The log, by contrast,
  unambiguously shows whether retries happened and whether the soft fallback ran.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Dragonex.{Archetypes, Games, Game, Monsters}
  alias Dragonex.GameRetryTest.FlakyModel
  alias ExAgent.RequestError

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragonex.Repo, {:shared, self()})

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

  # The recovery beat produced once the provider stops failing: a plain
  # narration line (no tool call) is enough — we only care that the beat
  # completed and the turn advanced.
  @recovery "El goblin se reacomoda y gruñe, midiendo al enemigo."

  # Run the game until the human (Thane) is waiting, capturing all logger
  # output produced along the way. The beat log lines ("retry N/3", "el turno
  # falló") are how we tell retry-vs-fallback apart without fragile counters.
  defp run_until_thane_waits(game_id, model) do
    capture_log(fn ->
      pid =
        ExUnit.Callbacks.start_supervised!(
          {Dragonex.Game, {game_id, [model: model, roller: hit_roller()]}}
        )

      assert :ok == Game.await(pid, waiting_on("Thane"), 8_000)
    end)
  end

  defp failed_turn?(log) do
    log =~ "el turno falló"
  end

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

  test "exhausting transient retries falls back to the soft narration" do
    game = new_game()

    # Fails forever: the 3-retry budget is exhausted on every beat that runs.
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

    log = run_until_thane_waits(game.id, model)

    # All three retries fired before giving up...
    assert log =~ "retry 3/3"
    # ...and then the soft fallback narration took over.
    assert failed_turn?(log)
    assert system_failure_events(game.id) != []
  end

  test "a non-transient 400 falls back immediately without retrying" do
    game = new_game()

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

    log = run_until_thane_waits(game.id, model)

    # A 400 is a client error — retrying won't help, so NO backoff retry fires.
    refute log =~ "retry 1/3"
    # The beat falls straight through to the soft fallback.
    assert failed_turn?(log)
    assert system_failure_events(game.id) != []
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

  test "the loop PAUSES after a streak of fallback beats (circuit breaker)" do
    # Roster with two AI agents that auto-act (no human :waiting to stop the
    # loop), so fallbacks can pile up: round-robin is dm → Thane(ai) → goblin(ai).
    {:ok, game} =
      Games.create_game(
        title: "breaker",
        scene: "una sala",
        roster: [{Archetypes.fighter(), :ai}, {Monsters.goblin(), :ai}]
      )

    # Always fails with a 400 (non-transient) → every beat falls straight to the
    # soft fallback. After @max_fallback_streak consecutive fallbacks the loop
    # must PAUSE instead of feeding another round of "X titubea".
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
      ExUnit.Callbacks.start_supervised!(
        {Dragonex.Game, {game.id, [model: model, roller: hit_roller()]}}
      )

    assert :ok == Game.await(pid, fn s -> s.status == :paused end, 15_000),
           "the partida should auto-pause after a streak of fallback beats"

    assert Game.status(pid) == :paused

    events = Games.list_events(game.id)

    assert Enum.any?(
             events,
             fn e ->
               e.type == :system and (e.payload["note"] || "") =~ "pausado automáticamente"
             end
           ),
           "a system note should explain the auto-pause"

    # And the fallback streak did NOT run away: only @max_fallback_streak
    # "titubea" narrations should have landed, not dozens.
    titubea_count =
      Enum.count(events, fn e ->
        e.type == :narration and (e.payload["text"] || "") =~ "titubea"
      end)

    assert titubea_count <= 6
  end

  # d20 always 15 (a hit), every other die 1 (minimal damage) — combat-safe.
  defp hit_roller do
    fn
      20 -> 15
      _n -> 1
    end
  end
end
