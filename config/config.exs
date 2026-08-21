import Config

config :phoenix, :json_library, Jason

config :dragonex, :generators, timestamp_type: :naive_datetime

config :dragonex, ecto_repos: [Dragonex.Repo]

config :dragonex, Dragonex.Repo, migration_timestamps: [type: :naive_datetime]

config :dragonex, DragonexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DragonexWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Dragonex.PubSub,
  live_view: [signing_salt: "dragonexdevsigningsalt0123"]

import_config "#{config_env()}.exs"
