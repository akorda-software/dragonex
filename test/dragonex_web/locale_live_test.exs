defmodule DragonexWeb.LocaleLiveTest do
  @moduledoc """
  Interface language of the web layer (D236): the ES | EN switch stores the
  visitor's locale in the session, the wizard picks the game's language, and
  the game table always renders in the game's locale.

  English wording is filled into the catalog separately, so these tests assert
  the locale each rendering process uses (and `<html lang>`), and compare
  labels against whatever the English catalog yields for their msgid.
  """
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "locale-#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "Políglota"
      })

    %{user: user}
  end

  defp logged_in(user, session \\ %{}) do
    build_conn() |> Plug.Test.init_test_session(session) |> DragonexWeb.UserAuth.log_in(user)
  end

  # Gettext keeps the locale in the process dictionary of the LiveView.
  defp view_locale(view) do
    {:dictionary, dict} = Process.info(view.pid, :dictionary)
    Keyword.get(dict, Dragonex.Gettext)
  end

  defp english(msgid),
    do:
      Gettext.with_locale(Dragonex.Gettext, "en", fn ->
        Gettext.dgettext(Dragonex.Gettext, "ui", msgid)
      end)

  describe "ES | EN switch" do
    test "pages render in Spanish by default and the top bar offers both languages" do
      html = build_conn() |> get("/login") |> html_response(200)

      assert html =~ ~s(<html lang="es">)
      assert html =~ ~s(href="/locale/es")
      assert html =~ ~s(href="/locale/en")
      assert html =~ "Vuelve a la mesa, aventurero."
    end

    test "switching to English stores it in the session and returns to the same page" do
      conn =
        build_conn()
        |> put_req_header("referer", "http://www.example.com/login?next=1")
        |> get("/locale/en")

      assert redirected_to(conn) == "/login?next=1"
      assert get_session(conn, "locale") == "en"

      html = conn |> get("/login") |> html_response(200)
      assert html =~ ~s(<html lang="en">)
      assert html =~ ~s(class="is-current" aria-current="true">EN</a>)
      assert Gettext.get_locale(Dragonex.Gettext) == "en"
      assert html =~ english("Vuelve a la mesa, aventurero.")
    end

    test "LiveViews follow the session locale", %{user: user} do
      {:ok, view, html} = live(logged_in(user, %{"locale" => "en"}), "/heroes")
      assert html =~ ~s(<html lang="en">)
      assert view_locale(view) == "en"

      {:ok, view, _html} =
        live(build_conn() |> Plug.Test.init_test_session(%{"locale" => "en"}), "/")

      assert view_locale(view) == "en"
    end

    test "foreign referers and unknown locales fall back safely" do
      conn =
        build_conn()
        |> put_req_header("referer", "https://evil.example.org/phish")
        |> get("/locale/fr")

      assert redirected_to(conn) == "/"
      assert get_session(conn, "locale") == "es"

      conn = build_conn() |> get("/locale/en")
      assert redirected_to(conn) == "/"
      assert get_session(conn, "locale") == "en"
    end
  end

  describe "new game wizard" do
    defp create_with_wizard(view) do
      view |> element("#scenario-custom") |> render_click()
      view |> render_click("next")
      view |> element("button[phx-click=pick_hero][phx-value-key=fighter]") |> render_click()
      view |> render_click("next")
      {path, _flash} = assert_redirect(view)
      Games.get_game(String.to_integer(String.replace_prefix(path, "/games/", "")))
    end

    test "the language defaults to the interface locale and the game is created in English",
         %{user: user} do
      {:ok, view, _} = live(logged_in(user), "/games/new")

      assert has_element?(view, "button#game-locale-es[aria-pressed=true]", "Español")
      assert has_element?(view, "button#game-locale-en[aria-pressed=false]", "English")

      view |> element("#game-locale-en") |> render_click()
      assert has_element?(view, "button#game-locale-en[aria-pressed=true]")

      game = create_with_wizard(view)
      assert game.locale == "en"
    end

    test "an English interface preselects English; Spanish can still be chosen", %{user: user} do
      {:ok, view, _} = live(logged_in(user, %{"locale" => "en"}), "/games/new")
      assert has_element?(view, "button#game-locale-en[aria-pressed=true]")

      view |> element("#game-locale-es") |> render_click()
      game = create_with_wizard(view)
      assert game.locale == "es"
    end
  end

  describe "game table" do
    defp table_game(user, locale, opts \\ []) do
      {:ok, game} =
        Games.create_game(
          [
            title: "Mesa #{locale}",
            scene: "Una sala",
            user_id: user.id,
            roster: [{Archetypes.fighter(), :human}],
            locale: locale
          ] ++ opts
        )

      game
    end

    test "an English game renders the table in English even for a Spanish visitor", %{user: user} do
      game = table_game(user, "en")
      {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})

      html = logged_in(user) |> get("/games/#{game.id}") |> html_response(200)
      assert html =~ ~s(<html lang="en">)

      {:ok, view, _} = live(logged_in(user), "/games/#{game.id}")
      assert view_locale(view) == "en"
      assert has_element?(view, "button#sheet-drawer", english("Ficha"))
    end

    test "a Spanish game stays Spanish for an English visitor", %{user: user} do
      game = table_game(user, "es")
      {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})

      html =
        logged_in(user, %{"locale" => "en"}) |> get("/games/#{game.id}") |> html_response(200)

      assert html =~ ~s(<html lang="es">)

      {:ok, view, _} = live(logged_in(user, %{"locale" => "en"}), "/games/#{game.id}")
      assert view_locale(view) == "es"
      assert has_element?(view, "button#sheet-drawer", "Ficha")
    end

    test "the waiting room of an English game renders in English", %{user: user} do
      game = table_game(user, "en", open_slots: 1)
      assert game.status == :configuring

      {:ok, view, _} = live(logged_in(user), "/games/#{game.id}")
      assert view_locale(view) == "en"
    end
  end
end
