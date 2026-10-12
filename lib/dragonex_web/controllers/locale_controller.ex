defmodule DragonexWeb.LocaleController do
  @moduledoc """
  ES | EN switch of the top bar: stores the interface locale in the session
  and sends the visitor back to the page they came from (same host only).
  """

  use DragonexWeb, :controller

  alias Dragonex.I18n
  alias DragonexWeb.Locale

  def update(conn, %{"locale" => locale}) do
    locale = locale |> I18n.normalize() |> Atom.to_string()

    conn
    |> put_session(Locale.session_key(), locale)
    |> redirect(to: Locale.back_path(conn))
  end
end
