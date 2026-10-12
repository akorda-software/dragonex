defmodule Dragonex.Accounts.ApiKey do
  @moduledoc """
  A player's own key for an AI provider (D242). `ciphertext` holds the key
  sealed by `Dragonex.Accounts.KeyVault`; only `hint` (its last characters) is
  ever shown back.
  """

  use Ecto.Schema

  alias Dragonex.Accounts.User

  @derive {Inspect, except: [:ciphertext]}
  schema "user_api_keys" do
    belongs_to(:user, User)
    field(:provider, :string)
    field(:ciphertext, :binary)
    field(:hint, :string)

    timestamps(type: :naive_datetime)
  end
end
