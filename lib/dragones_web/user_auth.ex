defmodule DragonesWeb.UserAuth do
  @moduledoc """
  Authentication plugs: fetch the current user from the session and enforce
  login for protected routes.

  Session-based: `user_id` is stored in the cookie session. LiveViews read
  `current_user` from the mount session (see `on_mount/3`).
  """

  import Plug.Conn
  import Phoenix.Component, only: [assign_new: 3]

  alias Dragones.Accounts

  @session_key "user_id"

  @doc "Remember the user in the session."
  def log_in(conn, user) do
    conn
    |> put_session(@session_key, user.id)
    |> configure_session(renew: true)
  end

  @doc "Drop the user from the session."
  def log_out(conn) do
    configure_session(conn, drop: true)
  end

  @doc """
  Plug: load the current user from the session into `conn.assigns.current_user`.
  Always passes through (even if not logged in).
  """
  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, @session_key)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_user, user)
  end

  @doc """
  Plug: redirect to the login page if there is no current user.
  """
  def require_login(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.redirect(to: "/login")
      |> halt()
    end
  end

  @doc """
  LiveView mount hooks. Use `on_mount DragonesWeb.UserAuth, :mount_current`
  to inject `current_user`, or `:ensure_authed` to also redirect if not logged in.
  """
  def on_mount(:mount_current, _params, session, socket) do
    {:cont, mount_current(socket, session)}
  end

  def on_mount(:ensure_authed, _params, session, socket) do
    socket = mount_current(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  defp mount_current(socket, session) do
    user_id = session[@session_key]
    user = user_id && Accounts.get_user(user_id)

    assign_new(socket, :current_user, fn -> user end)
  end
end
