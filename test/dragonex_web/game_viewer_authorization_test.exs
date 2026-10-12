defmodule DragonexWeb.GameViewerAuthorizationTest do
  use DragonexWeb.ConnCase, async: false

  alias Dragonex.{Accounts, Archetypes, Game, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    owner = register("Owner")
    guest = register("Guest")

    {:ok, game} =
      Games.create_game(
        title: "Mesa compartida",
        scene: "Una sala tranquila",
        user_id: owner.id,
        open_slots: 1,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, game} = Games.join_game(game, guest, Archetypes.wizard())
    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})
    {:ok, _} = Games.append_event(game.id, :narration, "dm", "dm", %{text: "Secreto del DM"})

    %{game: game, owner_conn: login(owner), guest_conn: login(guest)}
  end

  # D228 pause notes ask to resume; only the creator holds that control.
  test "a paused table tells the guest who can resume it", %{
    game: game,
    guest_conn: guest_conn,
    owner_conn: owner_conn
  } do
    {:ok, guest, _} = live(guest_conn, "/games/#{game.id}")
    assert has_element?(guest, ".whose-turn", "la reanuda quien creó la partida")
    assert has_element?(guest, ".whose-turn", ~r/^En pausa · /)
    refute has_element?(guest, "button[phx-click=resume]")

    {:ok, owner, _} = live(owner_conn, "/games/#{game.id}")
    assert has_element?(owner, ".whose-turn", "En pausa")
    refute has_element?(owner, ".whose-turn", "la reanuda")
    assert has_element?(owner, "button[phx-click=resume]", "Reanudar")
  end

  test "the pause notice by the input gives the retained turn's reason and its control", %{
    game: game,
    guest_conn: guest_conn,
    owner_conn: owner_conn
  } do
    {:ok, owner, _} = live(owner_conn, "/games/#{game.id}")
    assert has_element?(owner, ".pause-banner", "La partida está en pausa.")
    assert has_element?(owner, ".whose-turn", "En pausa · tu turno")

    reason = "El turno del DM no pudo completarse. Reanuda para volver a intentarlo."

    {:ok, _} =
      Games.append_event(game.id, :system, "system", "all", %{kind: "turn_retained", note: reason})

    {:ok, owner, _} = live(owner_conn, "/games/#{game.id}")
    assert has_element?(owner, ".pause-banner", reason)
    assert has_element?(owner, ".pause-banner button[phx-click=resume]", "Reanudar")

    {:ok, guest, _} = live(guest_conn, "/games/#{game.id}")
    assert has_element?(guest, ".whose-turn", "En pausa · turno de Thane")
    assert has_element?(guest, ".pause-banner", reason)
    refute has_element?(guest, ".pause-banner button")
  end

  test "a participant cannot obtain the DM view through the URL or a live patch", %{
    game: game,
    guest_conn: conn
  } do
    {:ok, view, html} = live(conn, "/games/#{game.id}?as=dm")
    assert has_element?(view, ".viewer-tag", "Lyra")
    refute html =~ "Secreto del DM"

    render_patch(view, "/games/#{game.id}?as=Thane")
    assert has_element?(view, ".viewer-tag", "Lyra")
    refute render(view) =~ "Secreto del DM"
  end

  test "a forged character selector only declares and enables auto-play for the user's own PC", %{
    game: game,
    guest_conn: conn
  } do
    {:ok, view, _} = live(conn, "/games/#{game.id}?as=Thane")
    assert has_element?(view, ".viewer-tag", "Lyra")

    view |> form("#player-input", text: "Examino el arcón") |> render_submit()
    pid = Dragonex.Game.Supervisor.whereis(game.id)
    assert Game.snapshot(pid).intents == %{"Lyra" => "Examino el arcón"}

    render_click(view, "toggle_auto")
    assert Game.snapshot(pid).auto == MapSet.new(["Lyra"])
  end

  test "the creator can inspect DM secrets and return to their own PC", %{
    game: game,
    owner_conn: conn
  } do
    {:ok, view, html} = live(conn, "/games/#{game.id}?as=dm")
    assert has_element?(view, ".viewer-tag", "Vista del DM")
    assert html =~ "Secreto del DM"

    render_patch(view, "/games/#{game.id}?as=Lyra")
    assert has_element?(view, ".viewer-tag", "Thane")
    refute render(view) =~ "Secreto del DM"
  end

  test "an unknown selector keeps the user's seat available", %{game: game, guest_conn: conn} do
    {:ok, view, _} = live(conn, "/games/#{game.id}?as=desconocido")
    assert has_element?(view, ".viewer-tag", "Lyra")
    assert has_element?(view, "#player-input-text:not([disabled])")
  end

  defp register(name) do
    {:ok, user} =
      Accounts.register(%{
        email: "viewer-#{name}-#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: name
      })

    user
  end

  defp login(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> DragonexWeb.UserAuth.log_in(user)
  end
end
