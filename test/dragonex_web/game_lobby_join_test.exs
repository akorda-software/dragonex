defmodule DragonexWeb.GameLobbyJoinTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    owner = user("Anfitrión")
    guest = user("Invitada")
    other = user("Otra invitada")
    {:ok, hero} = Accounts.save_hero(guest, %{Archetypes.wizard() | name: "Nara"})
    {:ok, foreign} = Accounts.save_hero(owner, Archetypes.rogue())
    {:ok, collision} = Accounts.save_hero(guest, Archetypes.fighter())

    {:ok, game} =
      Games.create_game(
        title: "Elegir compañero",
        user_id: owner.id,
        open_slots: 1,
        roster: [{Archetypes.fighter(), :human}]
      )

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(guest)

    %{
      game: game,
      owner: owner,
      guest: guest,
      other: other,
      hero: hero,
      foreign: foreign,
      collision: collision,
      conn: conn
    }
  end

  defp user(name) do
    {:ok, user} =
      Accounts.register(%{
        email: "lobby-feedback-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: name
      })

    user
  end

  test "an unavailable hero shows an alert and choosing one's own hero clears the error", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    render_click(view, "join_with_hero", %{"hero_id" => ctx.foreign.id})
    assert has_element?(view, "#lobby-join-error[role=alert]", "Héroe no encontrado")
    assert has_element?(view, ".hero-picker")

    assert has_element?(
             view,
             "button[phx-value-hero_id='#{ctx.hero.id}'][aria-describedby='lobby-join-error']"
           )

    assert Games.get_game(ctx.game.id).open_slots == 1
    refute Enum.any?(Games.get_game(ctx.game.id).participants, &(&1.user_id == ctx.guest.id))

    view |> element("button[phx-value-hero_id='#{ctx.hero.id}']") |> render_click()
    refute has_element?(view, "#lobby-join-error")
    refute has_element?(view, "button[aria-describedby='lobby-join-error']")
    assert has_element?(view, ".slot-card.you .sname", "Nara")
    refute has_element?(view, ".hero-picker")
    assert Games.get_game(ctx.game.id).open_slots == 0
  end

  test "a slot taken after the picker opened gives a reason and shows the current full room",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    assert {:ok, _} = Games.join_game(ctx.game, ctx.other, Archetypes.rogue())
    view |> element("button[phx-value-hero_id='#{ctx.hero.id}']") |> render_click()
    assert has_element?(view, "#lobby-join-error[role=alert]", "no tiene plazas libres")
    assert has_element?(view, ".sidebar", "La sala está completa")
    refute has_element?(view, ".hero-picker")
    refute Enum.any?(Games.get_game(ctx.game.id).participants, &(&1.user_id == ctx.guest.id))
  end

  test "a name collision leaves the hero available and allows a different choice", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    view |> element("button[phx-value-hero_id='#{ctx.collision.id}']") |> render_click()

    assert has_element?(
             view,
             "#lobby-join-error[role=alert]",
             "Ya hay un personaje llamado Thane"
           )

    assert has_element?(view, ".hero-picker")
    refute Accounts.hero_used?(ctx.collision.id)
    view |> element("button[phx-value-hero_id='#{ctx.hero.id}']") |> render_click()
    refute has_element?(view, "#lobby-join-error")
    assert has_element?(view, ".slot-card.you .sname", "Nara")
  end

  test "malformed hero ids show an error without disconnecting the waiting room", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")

    for id <- ["no-es-un-id", "", "-1"] do
      render_click(view, "join_with_hero", %{"hero_id" => id})
      assert has_element?(view, "#lobby-join-error[role=alert]", "Héroe no encontrado")
      assert Process.alive?(view.pid)
    end

    assert Games.get_game(ctx.game.id).open_slots == 1
  end

  test "a full-room broadcast removes the picker and replaces the invitation with its actual status",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    assert {:ok, _} = Games.join_game(ctx.game, ctx.other, Archetypes.rogue())

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{ctx.game.id}",
      {:game_updated, ctx.game.id}
    )

    assert has_element?(view, ".sidebar", "La sala está completa")
    refute has_element?(view, ".hero-picker")
    refute has_element?(view, ".sidebar", "Elige un héroe para unirte")
  end

  test "a room started after the picker opened shows why joining is no longer possible", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    assert {:ok, _} = Games.start_game(ctx.game.id)
    view |> element("button[phx-value-hero_id='#{ctx.hero.id}']") |> render_click()
    assert has_element?(view, "#lobby-join-error[role=alert]", "La partida ya ha empezado")
    refute has_element?(view, ".hero-picker")
    refute Enum.any?(Games.get_game(ctx.game.id).participants, &(&1.user_id == ctx.guest.id))
  end

  test "a repeated join keeps the user's original seat and clears any obsolete alert", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    view |> element("button[phx-value-hero_id='#{ctx.hero.id}']") |> render_click()
    before = Games.get_game(ctx.game.id)
    render_click(view, "join_with_hero", %{"hero_id" => ctx.hero.id})
    refute has_element?(view, "#lobby-join-error")
    assert has_element?(view, ".slot-card.you .sname", "Nara")
    assert MapSet.new(Games.get_game(ctx.game.id).participants) == MapSet.new(before.participants)
    assert Games.load_world(Games.get_game(ctx.game.id)) == Games.load_world(before)
  end

  test "a room deleted while the picker was open redirects with a recovery message", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    assert {:ok, _} = Games.delete_game(ctx.owner, ctx.game.id)
    view |> element("button[phx-value-hero_id='#{ctx.hero.id}']") |> render_click()

    assert %{"error" => "La partida ya no está disponible. Vuelve a tus partidas."} =
             assert_redirect(view, "/")
  end

  test "a waiting-room update after deletion redirects without crashing the connection", ctx do
    {:ok, view, _} = live(ctx.conn, "/games/#{ctx.game.id}")
    assert {:ok, _} = Games.delete_game(ctx.owner, ctx.game.id)

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{ctx.game.id}",
      {:game_updated, ctx.game.id}
    )

    assert %{"error" => "La partida ya no está disponible. Vuelve a tus partidas."} =
             assert_redirect(view, "/")
  end

  test "the creator cannot start a room deleted while the start button was visible", ctx do
    conn =
      build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(ctx.owner)

    {:ok, view, _} = live(conn, "/games/#{ctx.game.id}")
    assert {:ok, _} = Games.delete_game(ctx.owner, ctx.game.id)
    result = render_click(view, "start_game", %{})

    assert %{"error" => "La partida ya no está disponible. Vuelve a tus partidas."} =
             assert_redirect(view, "/")

    {:ok, index, _} = follow_redirect(result, conn, "/")

    assert has_element?(
             index,
             "#app-flash-error[role=alert]",
             "La partida ya no está disponible."
           )

    index |> element("#app-flash-error button") |> render_click()
    refute has_element?(index, "#app-flash-error")
  end
end
