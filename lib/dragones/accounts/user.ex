defmodule Dragones.Accounts.User do
  @moduledoc """
  A registered player. Owns heroes (created characters) and games (partidas).

  Passwords are hashed with bcrypt (`Bcrypt.hash_pwd_salt/1`). The `password_hash`
  column stores the hash; the plaintext never touches the database.
  """

  use Ecto.Schema

  schema "users" do
    field(:email, :string)
    field(:password, :string, virtual: true, redact: true)
    field(:password_hash, :string, redact: true)
    field(:display_name, :string)

    has_many(:heroes, Dragones.Accounts.Hero)
    has_many(:games, Dragones.Games.Game)

    timestamps(type: :naive_datetime)
  end
end
