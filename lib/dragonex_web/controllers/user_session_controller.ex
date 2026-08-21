defmodule DragonexWeb.UserSessionController do
  @moduledoc """
  Classic controller-based auth (login / register / logout).

  Uses session cookies — no tokens. After login/register the user is redirected
  to the lobby (`/`).
  """

  use DragonexWeb, :controller

  alias Dragonex.Accounts
  alias DragonexWeb.UserAuth

  def login_form(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render(conn, :login)
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in(user)
        |> put_flash(:info, "¡Bienvenido de nuevo, #{user.display_name}!")
        |> redirect(to: "/")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "Email o contraseña incorrectos.")
        |> render(:login)
    end
  end

  def register_form(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render(conn, :register)
    end
  end

  def register(conn, %{"email" => email, "password" => password, "display_name" => name}) do
    case Accounts.register(%{email: email, password: password, display_name: name}) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in(user)
        |> put_flash(:info, "¡Cuenta creada! Bienvenido, #{user.display_name}.")
        |> redirect(to: "/")

      {:error, changeset} ->
        errors = format_errors(changeset)

        conn
        |> put_flash(:error, errors)
        |> render(:register)
    end
  end

  def logout(conn, _params) do
    conn
    |> UserAuth.log_out()
    |> put_flash(:info, "Sesión cerrada.")
    |> redirect(to: "/login")
  end

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {_field, {msg, _}} -> msg end)
    |> Enum.uniq()
    |> Enum.join("; ")
  end
end
