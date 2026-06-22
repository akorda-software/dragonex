defmodule Dragones.Repo do
  use Ecto.Repo,
    otp_app: :dragones,
    adapter: Ecto.Adapters.Postgres
end
