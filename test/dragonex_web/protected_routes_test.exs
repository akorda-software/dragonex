defmodule DragonexWeb.ProtectedRoutesTest do
  @moduledoc """
  AC-1.2: las rutas protegidas (pipe `:auth` → `on_mount :ensure_authed`,
  router.ex) redirigen a /login sin sesión iniciada.
  """

  use DragonexWeb.ConnCase, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @protected_routes [
    "/heroes",
    "/heroes/new",
    "/heroes/1/edit",
    "/heroes/1/level-up",
    "/heroes/1",
    "/mi-contenido",
    "/games/new",
    "/games/1"
  ]

  test "sin sesión, cada ruta protegida redirige a /login" do
    for path <- @protected_routes do
      # The `:auth` plug redirects the disconnected (HTTP) render; the
      # `:ensure_authed` mount hook live-redirects the connected one —
      # either way, an anonymous visitor must land on /login.
      assert {:error, {kind, %{to: to}}} = live(build_conn(), path),
             "expected #{path} to require login"

      assert kind in [:redirect, :live_redirect]
      assert to == "/login", "#{path} redirected to #{to} instead of /login"
    end
  end

  test "con sesión, la misma ruta monta (control del caso positivo)" do
    {:ok, user} =
      Dragonex.Accounts.register(%{
        email: "auth#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "Authed"
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    # The hero gallery mounts when logged in (the rest share the same pipe).
    assert {:ok, _view, html} = live(conn, "/heroes")
    assert html =~ "Héroes"
  end
end
