defmodule DragonexWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :dragonex

  @session_options [
    store: :cookie,
    key: "_dragonex_key",
    signing_salt: "dragonexdev",
    same_site: "lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Resolve assets from the package loaded by this VM. Independent local/Hex
  # builds cannot overwrite another VM's vendored renderer.
  plug(Plug.Static,
    at: "/assets",
    from: {:dic_ex, "priv/static"},
    gzip: false,
    only: ~w(dic_ex.min.js dic_ex.css)
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.mjs)
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.Static,
    at: "/",
    from: :dragonex,
    gzip: false,
    only: ~w(assets)
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(DragonexWeb.Router)
end
