import Config

config :dragonex, Dragonex.Repo,
  hostname: "127.0.0.1",
  port: 5432,
  username: "postgres",
  password: "postgres",
  database: "dragonex_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :dragonex, DragonexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  debug_errors: true,
  code_reloader: true,
  reloadable_apps: [:dragonex, :exagent, :dic_ex],
  check_origin: false,
  watchers: [],
  secret_key_base: "dragonexdevsecretkeybase_for_dev_only_need_64_chars_total_padding1"

# Dev picks any OpenRouter/OpenCode model with the server keys; production
# pays only for the house model (D242, Dragonex.Models.server_mode/0).
config :dragonex, :server_models, :open
