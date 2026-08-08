import Config

# Solo en dev/test: carga las variables de .env.dev en el entorno del sistema
# para que System.get_env funcione en runtime sin tener que hacer `source .env.dev`.
# runtime.exs se evalúa cuando las dependencias ya están cargadas (a diferencia
# de dev.exs), por lo que Dotenvy está disponible aquí. Los valores ya presentes
# en el entorno real tienen prioridad sobre el .env.dev.
if config_env() in [:dev, :test] do
  case Dotenvy.source([".env.dev", System.get_env()]) do
    {:ok, vars} -> System.put_env(vars)
    {:error, _reason} -> :ok
  end

  # Override de DB desde entorno (p.ej. dentro de compose.dev.yml: DB_HOST=postgres,
  # o en host: DB_PORT=5455 vía .env.dev). Defaults que no cambian el flujo por defecto.
  default_db = if config_env() == :test, do: "dragones_test", else: "dragones_dev"

  config :dragones, Dragones.Repo,
    hostname: System.get_env("DB_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("DB_PORT", "5432")),
    username: System.get_env("DB_USER", "postgres"),
    password: System.get_env("DB_PASS", "postgres"),
    database: System.get_env("DB_NAME", default_db)
end

if config_env() == :dev do
  {:ok, bind_ip} =
    System.get_env("PHX_BIND_IP", "127.0.0.1") |> to_charlist() |> :inet.parse_address()

  config :dragones, DragonesWeb.Endpoint,
    http: [ip: bind_ip, port: String.to_integer(System.get_env("PORT", "4000"))]
end

# --- Producción (release) -----------------------------------------------------
# Las variables llegan inyectadas por Dokploy (env vars de la aplicación).
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      Ejemplo: ecto://USER:PASS@HOST:5432/DB
      """

  maybe_ipv6 =
    if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dragones, Dragones.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Genera uno con: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :dragones, DragonesWeb.Endpoint,
    server: System.get_env("PHX_SERVER") == "true",
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
