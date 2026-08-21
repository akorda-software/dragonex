import Config

config :dragonex, Dragonex.Repo,
  hostname: "127.0.0.1",
  port: 5432,
  username: "postgres",
  password: "postgres",
  database: "dragonex_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :dragonex, DragonexWeb.Endpoint,
  server: false,
  secret_key_base: "dragonex_test_secret_key_base_for_tests_only_padding_64_chars_ok"
