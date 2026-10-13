defmodule DragonexWeb.UserSessionController do
  @moduledoc """
  Classic controller-based auth (login / register / logout).

  Uses session cookies — no tokens. After login/register the user is redirected
  to the lobby (`/`).
  """

  use DragonexWeb, :controller
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Accounts
  alias DragonexWeb.UserAuth

  def login_form(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render(conn, :login, email: "")
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in(user)
        |> put_flash(
          :info,
          dgettext("ui", "¡Bienvenido de nuevo, %{name}!", name: user.display_name)
        )
        |> redirect(to: "/")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, dgettext("ui", "Email o contraseña incorrectos."))
        |> render(:login, email: email)
    end
  end

  def register_form(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render(conn, :register, values: %{}, errors: %{})
    end
  end

  def register(conn, %{"email" => email, "password" => password, "display_name" => name} = params) do
    attrs = %{
      email: email,
      password: password,
      # The form always repeats the password; a missing field never matches.
      password_confirmation: params["password_confirmation"] || "",
      display_name: name
    }

    case Accounts.register(attrs) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in(user)
        |> put_flash(
          :info,
          dgettext("ui", "¡Cuenta creada! Bienvenido, %{name}.", name: user.display_name)
        )
        |> redirect(to: "/")

      {:error, changeset} ->
        conn
        |> put_flash(:error, dgettext("ui", "Revisa los campos marcados."))
        |> render(:register,
          values: %{"display_name" => name, "email" => email},
          errors: field_errors(changeset)
        )
    end
  end

  def logout(conn, _params) do
    conn
    |> UserAuth.log_out()
    |> put_flash(:info, dgettext("ui", "Sesión cerrada."))
    |> redirect(to: "/login")
  end

  # One message per form field, the first check it failed (Ecto prepends, so
  # the last pair wins). The confirmation's error belongs to its own field.
  defp field_errors(changeset) do
    changeset.errors
    |> Map.new(fn {field, error} ->
      {to_string(field), DragonexWeb.ErrorTranslation.translate_error(error)}
    end)
  end
end
