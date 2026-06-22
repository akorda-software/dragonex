import Config

config :dragones, Dragones.Repo,
  hostname: "127.0.0.1",
  port: 5432,
  username: "postgres",
  password: "postgres",
  database: "dragones_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :dragones, DragonesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: true,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [],
  secret_key_base: "dragonesdevsecretkeybase_for_dev_only_need_64_chars_total_padding1"
