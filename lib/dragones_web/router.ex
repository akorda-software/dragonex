defmodule DragonesWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  import DragonesWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {DragonesWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:fetch_current_user)
  end

  pipeline :auth do
    plug(:require_login)
  end

  scope "/", DragonesWeb do
    pipe_through(:browser)

    # Auth (public)
    get("/register", UserSessionController, :register_form)
    post("/register", UserSessionController, :register)
    get("/login", UserSessionController, :login_form)
    post("/login", UserSessionController, :login)
    delete("/logout", UserSessionController, :logout)

    # Lobby — accessible to all (shows prompt if not logged in).
    live("/", GameLive.Index, :index)

    # Protected routes
    scope "/" do
      pipe_through(:auth)

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
