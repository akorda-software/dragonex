defmodule DragonexWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  import DragonexWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(DragonexWeb.Locale)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {DragonexWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:fetch_current_user)
  end

  pipeline :auth do
    plug(:require_login)
  end

  scope "/", DragonexWeb do
    pipe_through(:browser)

    # Auth (public)
    get("/register", UserSessionController, :register_form)
    post("/register", UserSessionController, :register)
    get("/login", UserSessionController, :login_form)
    post("/login", UserSessionController, :login)
    delete("/logout", UserSessionController, :logout)

    # Interface language (ES | EN switch of the top bar)
    get("/locale/:locale", LocaleController, :update)

    live_session :public,
      on_mount: [DragonexWeb.Locale, {DragonexWeb.UserAuth, :mount_current}] do
      live("/", GameLive.Index, :index)
    end

    scope "/" do
      pipe_through(:auth)

      live_session :authed,
        on_mount: [DragonexWeb.Locale, {DragonexWeb.UserAuth, :ensure_authed}] do
        live("/heroes", HeroLive.Index, :index)
        live("/heroes/new", HeroLive.New, :new)
        live("/heroes/:id/edit", HeroLive.New, :edit)
        live("/heroes/:id/level-up", HeroLive.LevelUp, :level_up)
        live("/heroes/:id", HeroLive.Show, :show)
        live("/mi-contenido", CustomContentLive, :index)
        live("/games/new", GameLive.New, :new)
        live("/games/:game_id", GameLive.Show, :show)
      end
    end
  end
end
