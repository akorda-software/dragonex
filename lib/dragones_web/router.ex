defmodule DragonesWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {DragonesWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/", DragonesWeb do
    pipe_through :browser

    live "/", GameLive.Index, :index
    live "/games/new", GameLive.New, :new
    live "/games/:game_id", GameLive.Show, :show
  end
end
