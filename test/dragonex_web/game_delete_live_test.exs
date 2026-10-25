defmodule DragonexWeb.GameDeleteLiveTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias Dragonex.Game.{Supervisor, TableSupervisor}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    user = register()
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{user: user, conn: conn}
  end

  test "deleting from the lobby closes the whole table and preserves another game", ctx do
    {game, pid} = paused_game(ctx.user)
    {other, other_pid} = paused_game(ctx.user)
    other_world = Game.world(other_pid)
    other_events = Games.list_events(other.id)
    processes = table_processes(game.id, pid)
    monitors = Enum.map(processes, &{&1, Process.monitor(&1)})
    {:ok, view, _} = live(ctx.conn, "/")

    view |> element("button[phx-click=delete][phx-value-id='#{game.id}']") |> render_click()

    for {process, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^process, _}, 1_000
    end

    assert Games.get_game(game.id) == nil
    assert Supervisor.whereis(game.id) == nil
    assert TableSupervisor.whereis(game.id) == nil
    refute has_element?(view, "button[phx-value-id='#{game.id}']")
    assert Supervisor.whereis(other.id) == other_pid
    assert Game.world(other_pid) == other_world
    assert Games.list_events(other.id) == other_events
    assert Game.status(other_pid) == :paused
  end

  test "deleting a running table cancels its pending model request", ctx do
    parent = self()

    model = %ExAgent.Models.Test{
      script: [
        fn _, _ ->
          send(parent, {:request_started, self()})

          receive do
            :release -> "Una narración que ya no corresponde publicar."
          end
        end
      ]
    }

    {game, pid} = paused_game(ctx.user, model)
    assert :ok == Game.resume(pid)
    assert_receive {:request_started, request}, 2_000
    monitor = Process.monitor(request)
    {:ok, view, _} = live(ctx.conn, "/")

    view |> element("button[phx-click=delete][phx-value-id='#{game.id}']") |> render_click()

    assert_receive {:DOWN, ^monitor, :process, ^request, _}, 1_000
    assert Games.get_game(game.id) == nil
    assert Supervisor.whereis(game.id) == nil
    assert TableSupervisor.whereis(game.id) == nil
  end

  test "a forged deletion cannot stop someone else's live table", ctx do
    {game, pid} = paused_game(register())
    world = Game.world(pid)
    events = Games.list_events(game.id)
    processes = table_processes(game.id, pid)
    {:ok, view, _} = live(ctx.conn, "/")

    render_click(view, "delete", %{"id" => to_string(game.id)})

    assert Enum.all?(processes, &Process.alive?/1)
    assert Games.get_game(game.id) != nil
    assert Game.world(pid) == world
    assert Games.list_events(game.id) == events
    assert Game.status(pid) == :paused
  end

  defp register do
    {:ok, user} =
      Accounts.register(%{
        email: "delete-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    user
  end

  defp paused_game(user, model \\ %ExAgent.Models.Test{}) do
    {:ok, game} =
      Games.create_game(
        title: "Una mesa efímera",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "dm", 1, :paused, %{})
    {:ok, pid} = Game.ensure_started(game.id, model: model)
    {game, pid}
  end

  defp table_processes(id, pid) do
    state = :sys.get_state(pid)

    [TableSupervisor.whereis(id), pid, state.session, state.dm, state.turnmaster] ++
      Map.values(state.pc_agents)
  end
end
