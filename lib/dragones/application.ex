defmodule Dragones.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dragones.Repo,
      {Phoenix.PubSub, name: Dragones.PubSub},
      {Registry, keys: :unique, name: Dragones.Game.Registry},
      {Dragones.Game.Supervisor, []},
      DragonesWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Dragones.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
