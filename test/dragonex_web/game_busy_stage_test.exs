defmodule DragonexWeb.GameBusyStageTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  defmodule RetryModel do
    @behaviour ExAgent.Model
    defstruct [:counter, :owner]

    def request(model, messages, settings, params) do
      if Agent.get_and_update(model.counter, fn n -> {n > 0, max(n - 1, 0)} end) do
        if model.owner do
          send(model.owner, {:provider_started, self()})
          receive do: (:finish -> :ok)
        end

        {:error, %ExAgent.RequestError{provider: :openrouter, reason: :timeout}}
      else
        {:ok, response, _} =
          Test.request(
            %Test{script: [narration("Thane, ¿qué haces?")]},
            messages,
            settings,
            params
          )

        {:ok, response, model}
      end
    end

    def request_stream(model, messages, settings, params) do
      case request(model, messages, settings, params) do
        {:ok, response, updated} -> [Dragonex.Test.Harness.stream_response(response, updated)]
        {:error, reason} -> [{:error, reason}]
      end
    end

    def model_name(_), do: "retry-stage-test"
    def system(_), do: "test"
    def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
  end

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "stages-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Esperas claras",
        scene: "El patio tranquilo.",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    world = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{conn: conn, game: game, world: world}
  end

  defp block(parent, tag, result) do
    fn _, _ ->
      send(parent, {tag, self()})
      receive do: (:finish -> result)
    end
  end

  test "scene review is accessible in two views and reload, hides late streaming and preserves the draft",
       %{
         conn: conn,
         game: game,
         world: world
       } do
    final = "Thane, ¿cómo seguimos? El botón está guardado."

    model = %Test{
      script: [
        block(
          self(),
          :actor_started,
          tool_calls([
            call("grant_item", %{"who" => "Thane", "item" => "botón", "quantity" => 1})
          ])
        ),
        narration(final)
      ]
    }

    recorder = %Test{
      script: [
        block(
          self(),
          :review_started,
          tool_calls([call("final_result", %{"scene" => world.scene})])
        )
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, scene_model: recorder]}})

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    draft = "Después quiero examinar el patio."
    view |> form("#player-input", %{"text" => draft}) |> render_change()
    assert :ok = Game.resume(pid)
    assert_receive {:actor_started, actor}, 2_000
    assert has_element?(view, ".thinking[role=status]", "el DM está narrando…")
    beat = :sys.get_state(pid).busy
    send(view.pid, {:text_delta, game.id, beat.turn_id, "dm", "Texto provisional"})
    assert has_element?(view, ".live-streaming", "Texto provisional")
    send(actor, :finish)
    assert_receive {:review_started, run}, 2_000
    assert :ok = Game.await(pid, &(&1.busy_stage == :scene_review))

    for active <- [view, elem(live(conn, "/games/#{game.id}"), 1)] do
      assert has_element?(
               active,
               ".thinking[role=status][aria-live=polite]",
               "Actualizando la escena…"
             )

      refute has_element?(active, ".live-streaming")
      refute has_element?(active, ".thinking", "narrando")
      refute has_element?(active, "#player-input button", "Actuar")
      assert has_element?(active, "#player-input button", "Declarar")

      rows =
        render(active)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#log .msg-dm")
        |> Enum.to_list()

      assert Enum.count(rows, &(String.trim(LazyHTML.text(&1)) == final)) == 1
    end

    send(view.pid, {:text_delta, game.id, beat.turn_id, "dm", "Chunk tardío"})
    refute has_element?(view, ".live-streaming")
    assert has_element?(view, "#player-input-text[value='#{draft}']")
    assert :ok = Game.pause(pid)
    refute has_element?(view, ".thinking")
    assert :ok = Game.resume(pid)
    assert has_element?(view, ".thinking", "Actualizando la escena…")
    send(run, :finish)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert has_element?(view, "#player-input button", "Actuar")
    refute has_element?(view, ".thinking")
    assert has_element?(view, "#player-input-text[value='#{draft}']")
    assert :ok = Game.pause(pid)
  end

  test "selecting the next turn is distinct from narrating and clears when the human receives it",
       %{
         conn: conn,
         game: game,
         world: world
       } do
    decision = tool_calls([call("give_turn_to", %{"participant" => "Thane"})])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("El patio está tranquilo.")]},
            turnmaster_model: %Test{script: [block(self(), :handoff_started, decision), "Listo."]}
          ]}}
      )

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert :ok = Game.resume(pid)
    assert_receive {:handoff_started, run}, 2_000
    assert Game.current(pid) == "dm"
    assert has_element?(view, ".thinking[role=status]", "Organizando el siguiente turno…")
    refute has_element?(view, ".thinking", "narrando")
    refute has_element?(view, "#player-input button", "Actuar")
    assert Game.world(pid) == world
    send(run, :finish)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    refute has_element?(view, ".thinking")
    assert has_element?(view, "#player-input button", "Actuar")
    assert :ok = Game.pause(pid)
  end

  test "a provider backoff announces a retry rather than an active narrator", %{
    conn: conn,
    game: game
  } do
    previous = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [60_000])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dragonex, :transient_backoffs, previous),
        else: Application.delete_env(:dragonex, :transient_backoffs)
    end)

    counter = start_supervised!({Agent, fn -> 1 end})

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %RetryModel{counter: counter}]}})

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.busy_stage == :retrying))

    assert has_element?(
             view,
             ".thinking[role=status][aria-live=polite]",
             "Reintentando el turno…"
           )

    refute has_element?(view, ".thinking", "narrando")
    refute has_element?(view, ".live-streaming")
    refute has_element?(view, "#player-input button", "Actuar")
    pending = :sys.get_state(pid).busy
    assert :ok = Game.pause(pid)
    refute has_element?(view, ".thinking")
    assert :ok = Game.resume(pid)
    assert has_element?(view, ".thinking", "Reintentando el turno…")
    send(pid, {:retry_beat, pending.turn_id})
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    refute has_element?(view, ".thinking")
    assert :ok = Game.pause(pid)
  end

  test "a provider failure arriving after pause cannot resume the game", %{conn: conn, game: game} do
    previous = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [60_000])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dragonex, :transient_backoffs, previous),
        else: Application.delete_env(:dragonex, :transient_backoffs)
    end)

    counter = start_supervised!({Agent, fn -> 1 end})

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %RetryModel{counter: counter, owner: self()}]}}
      )

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert :ok = Game.resume(pid)
    assert_receive {:provider_started, run}, 2_000
    assert :ok = Game.pause(pid)
    before = Game.world(pid)
    events_before = Games.list_events(game.id)
    send(run, :finish)

    assert :ok =
             Game.await(pid, fn _ ->
               match?(%Dragonex.Game.PendingRetry{}, :sys.get_state(pid).busy)
             end)

    assert %{status: :paused, busy_stage: nil} = Game.snapshot(pid)
    assert Game.world(pid) == before
    assert Games.get_game(game.id).status == :paused
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Games.list_events(game.id) == events_before
    assert has_element?(view, "button", "Reanudar")
    refute has_element?(view, ".thinking")
    refute has_element?(view, ".live-streaming")
    pending = :sys.get_state(pid).busy
    assert :ok = Game.resume(pid)
    assert has_element?(view, ".thinking", "Reintentando el turno…")
    send(pid, {:retry_beat, pending.turn_id})
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert :ok = Game.pause(pid)
  end
end
