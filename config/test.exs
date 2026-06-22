import Config

config :dragones, Dragones.Repo,
  hostname: "127.0.0.1",
  port: 5432,
  username: "postgres",
  password: "postgres",
  database: "dragones_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :dragones, DragonesWeb.Endpoint,
  server: false,
  secret_key_base: "dragones_test_secret_key_base_for_tests_only_padding_64_chars_ok"
