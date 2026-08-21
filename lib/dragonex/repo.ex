defmodule Dragonex.Repo do
  use Ecto.Repo,
    otp_app: :dragonex,
    adapter: Ecto.Adapters.Postgres
end
