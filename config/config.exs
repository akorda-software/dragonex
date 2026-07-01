import Config

config :phoenix, :json_library, Jason

config :dragones, :generators, timestamp_type: :naive_datetime

config :dragones, ecto_repos: [Dragones.Repo]

config :dragones, Dragones.Repo, migration_timestamps: [type: :naive_datetime]

config :dragones, DragonesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DragonesWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Dragones.PubSub,
  live_view: [signing_salt: "dragonesdevsigningsalt0123"]

import_config "#{config_env()}.exs"
