defmodule DragonexWeb.HeroLevelUpLiveTest do
  @moduledoc """
  Flujo UI de la pantalla de subida de nivel (milestone): un héroe por debajo
  del nivel máximo puede subir sin necesidad de XP; a nivel 20 se redirige.
  """

  use DragonexWeb.ConnCase, async: false

  alias Dragonex.{Accounts, Heroes}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragonex.Repo, {:shared, self()})

    {:ok, user} =
      Accounts.register(%{
        email: "lu#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "LU"
      })

    {:ok, char} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, hero} = Accounts.save_hero(user, char)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn, user: user, hero: hero}
  end

  test "un héroe puede subir de nivel desde su ficha (milestone, sin XP)", %{
    conn: conn,
    user: user,
    hero: hero
  } do
    {:ok, view, html} = live(conn, "/heroes/#{hero.id}/level-up")
    assert html =~ "Subir de nivel"

    view |> render_click("confirm")

    assert Accounts.get_user_hero(user, hero.id).level == 2
    assert_redirect(view, "/heroes/#{hero.id}")
  end

  test "a nivel 20, /heroes/:id/level-up redirige a la ficha", %{
    conn: conn,
    user: user,
    hero: hero
  } do
    hero =
      Enum.reduce(1..19, hero, fn _, h ->
        {:ok, h2} = Accounts.level_up_hero(user, h.id, %{})
        h2
      end)

    assert hero.level == 20

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/heroes/#{hero.id}/level-up")
    assert to == "/heroes/#{hero.id}"
  end
end
