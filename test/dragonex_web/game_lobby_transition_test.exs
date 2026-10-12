defmodule DragonexWeb.GameLobbyTransitionTest do
  use DragonexWeb.ConnCase, async: false

  alias Dragonex.{Accounts, Archetypes, Game, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    owner = register("Anfitrión")
    guest = register("Invitada")

    {:ok, game} =
      Games.create_game(
        title: "El inicio ya llegó",
        user_id: owner.id,
        open_slots: 1,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, game} = Games.join_game(game, guest, Archetypes.wizard())

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(guest)

    %{game: game, conn: conn}
  end

  for status <- [:waiting, :paused] do
    test "a lobby update enters the table even if Game has already become #{status}", %{
      game: game,
      conn: conn
    } do
      {:ok, lobby, _} = live(conn, "/games/#{game.id}")
      assert has_element?(lobby, ".wr")
      refute has_element?(lobby, ".hero-picker")

      # Deliver the real startup notifications only after the engine settles,
      # as can happen to a busy socket. Intermediate :running is gone by then.
      :ok = :sys.suspend(lobby.pid)

      try do
        {:ok, _} = Games.start_game(game.id)

        pid =
          Dragonex.Test.GameFixture.start!(
            {Game,
             {game.id,
              [model: %Dragonex.Test.Narrator{text: "Thane, la mesa está preparada. ¿Qué haces?"}]}}
          )

        assert :ok = Game.await(pid, &(&1.status == :waiting))
        if unquote(status) == :paused, do: assert(:ok == Game.pause(pid))
        assert Games.get_game(game.id).status == unquote(status)
      after
        :ok = :sys.resume(lobby.pid)
      end

      Phoenix.PubSub.broadcast(
        Dragonex.PubSub,
        "dragonex:game:#{game.id}",
        {:game_updated, game.id}
      )

      assert_redirect(lobby, "/games/#{game.id}")
    end
  end

  defp register(name) do
    {:ok, user} =
      Accounts.register(%{
        email: "lobby-#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: name
      })

    user
  end
end
