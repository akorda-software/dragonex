import Config

# Dragonex carga sus credenciales en runtime.exs. ReqLLM no debe cargar otro .env.
if config_env() != :prod and
     not (config_env() == :test and System.get_env("DRAGONEX_DEPS_SOURCE") == "hex") do
  config :req_llm, load_dotenv: false
end

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
