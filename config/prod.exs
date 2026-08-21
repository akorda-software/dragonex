import Config

# Configuración de compilación para producción. La configuración dinámica
# (DATABASE_URL, SECRET_KEY_BASE, PHX_HOST, puerto...) se resuelve en
# runtime.exs a partir de las variables de entorno que inyecta Dokploy.

config :logger, level: :info

if System.get_env("PHX_SERVER") do
  config :dragonex, DragonexWeb.Endpoint, server: true
end
