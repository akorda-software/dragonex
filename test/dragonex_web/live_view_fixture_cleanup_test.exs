defmodule DragonexWeb.LiveViewFixtureCleanupTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  alias Dragonex.{Accounts, Archetypes, Game, Games, Repo}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "fixture shutdown lets a LiveView return its SQL connection before closing it" do
    {:ok, user} =
      Accounts.register(%{
        email: "view-close-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Una vista que termina su consulta",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %ExAgent.Models.Test{}]}})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert has_element?(view, ".card.mine .card-stats", "HP 12/12")
    events = Games.list_events(game.id)
    {:ok, test_supervisor} = ExUnit.fetch_test_supervisor()
    ref = Process.monitor(view.pid)
    owner = self()

    # A separate PostgreSQL connection holds an advisory lock, so the real
    # LiveView owns the shared SQL connection until this test releases it.
    config =
      Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database, :ssl])

    control = start_supervised!({Postgrex, config})
    lock = System.unique_integer([:positive])
    Postgrex.query!(control, "SELECT pg_advisory_lock($1)", [lock])

    query =
      Task.async(fn ->
        :sys.replace_state(view.pid, fn state ->
          send(owner, :client_query_started)
          Repo.query!("SELECT pg_advisory_lock($1)", [lock])
          Repo.query!("SELECT pg_advisory_unlock($1)", [lock])
          send(owner, :client_query_finished)
          state
        end)
      end)

    assert_receive :client_query_started
    assert :ok == await_lock(control, lock)
    snapshot = Task.async(fn -> Game.snapshot(pid) end)

    closing =
      Task.async(fn ->
        Supervisor.terminate_child(test_supervisor, {Dragonex.Test.LiveViewFixture, view.pid})
      end)

    try do
      assert Task.yield(closing, 30) == nil
      assert Process.alive?(view.pid)
      assert Task.yield(snapshot, 0) == nil
      Postgrex.query!(control, "SELECT pg_advisory_unlock($1)", [lock])
      assert_receive :client_query_finished
      Task.await(query, 2_000)
      assert Task.await(closing, 2_000) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert Task.await(snapshot, 2_000).world == world
      assert Game.world(pid) == world
      assert Games.load_world(Games.get_game(game.id)) == world
      assert Games.list_events(game.id) == events
      assert Game.status(pid) == :paused
    after
      Postgrex.query!(control, "SELECT pg_advisory_unlock($1)", [lock])
      Task.shutdown(query, :brutal_kill)
      Task.shutdown(closing, :brutal_kill)
      Task.shutdown(snapshot, :brutal_kill)
    end
  end

  test "closing one managed view preserves another view of the same paused Game" do
    {:ok, user} =
      Accounts.register(%{
        email: "view-reload-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Dos vistas de una partida",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %ExAgent.Models.Test{}]}})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, first, _} = live(conn, "/games/#{game.id}")
    {:ok, second, _} = live(conn, "/games/#{game.id}")
    assert Dragonex.Test.LiveViewFixture.manage({:ok, second, ""}) == {:ok, second, ""}
    assert :ok == stop_supervised({Dragonex.Test.LiveViewFixture, first.pid})
    refute Process.alive?(first.pid)
    assert Process.alive?(second.pid)

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{game.id}",
      {:game_updated, game.id}
    )

    assert has_element?(second, ".card.mine .card-stats", "HP 12/12")
    assert Game.snapshot(pid).world == world
    assert Games.load_world(Games.get_game(game.id)) == world
    assert :ok == stop_supervised({Dragonex.Test.LiveViewFixture, second.pid})
    refute Process.alive?(second.pid)
    assert Process.alive?(pid)
  end

  defp await_lock(control, lock, attempts \\ 200)
  defp await_lock(_control, _lock, 0), do: :timeout

  defp await_lock(control, lock, attempts) do
    result =
      Postgrex.query!(
        control,
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $1 AND NOT granted",
        [lock]
      )

    if result.rows == [[1]],
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_lock(control, lock, attempts - 1)
        )
  end
end
