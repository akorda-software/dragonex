import Config

# Solo en dev: carga las variables de .env en el entorno del sistema para que
# System.get_env funcione en runtime sin tener que hacer `source .env`.
# runtime.exs se evalúa cuando las dependencias ya están cargadas (a diferencia
# de dev.exs), por lo que Dotenvy está disponible aquí. Los valores ya presentes
# en el entorno real tienen prioridad sobre el .env.
if config_env() == :dev do
  case Dotenvy.source([".env", System.get_env()]) do
    {:ok, vars} -> System.put_env(vars)
    {:error, _reason} -> :ok
  end
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
