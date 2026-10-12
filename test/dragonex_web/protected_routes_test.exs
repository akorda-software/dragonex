defmodule DragonexWeb.ProtectedRoutesTest do
  @moduledoc """
  AC-1.2: las rutas protegidas (pipe `:auth` → `on_mount :ensure_authed`,
  router.ex) redirigen a /login sin sesión iniciada.
  """

  use DragonexWeb.ConnCase, async: false

  import Phoenix.ConnTest

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  @protected_routes [
    "/heroes",
    "/heroes/new",
    "/heroes/1/edit",
    "/heroes/1/level-up",
    "/heroes/1",
    "/mi-contenido",
    "/cuenta",
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
        email: "auth#{Ecto.UUID.generate()}@dragonex.test",
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

  test "login and register do not show a redacted email placeholder" do
    for path <- ["/login", "/register"] do
      html = html_response(get(build_conn(), path), 200)
      refute html =~ "__VG_EMAIL"
      assert html =~ ~s(placeholder="tu correo")
    end
  end
end
