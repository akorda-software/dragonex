defmodule DragonexWeb.GoogleAuthController do
  @moduledoc """
  Sign in with Google (D245). `/auth/google` sends the browser to Google with
  one-time secrets kept in the session; `/auth/google/callback` checks them,
  reads the identity and logs the player in (opening an account if needed).
  """

  use DragonexWeb, :controller
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Accounts
  alias Dragonex.Accounts.Google
  alias DragonexWeb.UserAuth

  @session_key "google_oauth"

  def request(conn, _params) do
    if Google.configured?() do
      {url, secrets} = Google.authorize(redirect_uri())

      conn
      |> put_session(@session_key, secrets)
      |> redirect(external: url)
    else
      fail(conn)
    end
  end

  def callback(conn, params) do
    secrets = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    with %{"state" => state} when is_binary(state) <- secrets,
         true <- Plug.Crypto.secure_compare(state, to_string(params["state"])),
         code when is_binary(code) <- params["code"],
         {:ok, identity} <- Google.identity(code, secrets, redirect_uri()),
         {:ok, user} <- Accounts.sign_in_with_google(identity) do
      conn
      |> UserAuth.log_in(user)
      |> put_flash(:info, dgettext("ui", "¡Bienvenido, %{name}!", name: user.display_name))
      |> redirect(to: "/")
    else
      {:error, :unverified} ->
        conn
        |> put_flash(:error, dgettext("ui", "Google no ha verificado ese correo."))
        |> redirect(to: "/login")

      _ ->
        fail(conn)
    end
  end

  defp fail(conn) do
    conn
    |> put_flash(:error, dgettext("ui", "No se pudo entrar con Google. Prueba otra vez."))
    |> redirect(to: "/login")
  end

  defp redirect_uri, do: DragonexWeb.Endpoint.url() <> "/auth/google/callback"
end
