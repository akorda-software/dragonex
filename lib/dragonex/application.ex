defmodule Dragonex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dragonex.Repo,
      {Phoenix.PubSub, name: Dragonex.PubSub},
      {Registry, keys: :unique, name: Dragonex.Game.Registry},
      {Registry, keys: :unique, name: Dragonex.Game.SupervisorRegistry},
      {Dragonex.Game.Supervisor, []},
      DragonexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Dragonex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
