defmodule DragonexWeb.Locale do
  @moduledoc """
  Interface language outside a game table (D236).

  The visitor's choice lives in the session (`"locale"`, `"es"` or `"en"`,
  default `"es"`). This module is both a plug (controllers and the dead render
  of LiveViews) and an `on_mount` hook (connected LiveViews), so every process
  that renders pages calls `Dragonex.I18n.put_locale/1` before rendering.

  The game table overrides it with the game's own locale after loading the
  game (`DragonexWeb.GameLive.Show`).
  """

  import Plug.Conn

  alias Dragonex.I18n

  @session_key "locale"

  @doc "Session key that stores the interface locale."
  def session_key, do: @session_key

  @doc "Locale stored in a session map (string keys), normalized."
  @spec from_session(map()) :: atom()
  def from_session(session) when is_map(session), do: I18n.normalize(session[@session_key])
  def from_session(_), do: I18n.default_locale()

  # ------------------------------------------------------------------ plug

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = I18n.normalize(get_session(conn, @session_key))
    I18n.put_locale(locale)
    assign(conn, :locale, Atom.to_string(locale))
  end

  # -------------------------------------------------------------- on_mount

  def on_mount(:default, _params, session, socket) do
    locale = from_session(session)
    I18n.put_locale(locale)
    {:cont, Phoenix.Component.assign(socket, :locale, Atom.to_string(locale))}
  end

  # ----------------------------------------------------------- redirection

  @doc """
  Same-host path to go back to after switching the language: the referer's
  path (and query) when it points at this host, otherwise `"/"`.
  """
  @spec back_path(Plug.Conn.t()) :: String.t()
  def back_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host, path: path, query: query} <- URI.parse(referer),
         true <- host == conn.host,
         "/" <> _ <- path,
         false <- String.starts_with?(path, ["//", "/locale/"]) do
      if query in [nil, ""], do: path, else: path <> "?" <> query
    else
      _ -> "/"
    end
  end
end
