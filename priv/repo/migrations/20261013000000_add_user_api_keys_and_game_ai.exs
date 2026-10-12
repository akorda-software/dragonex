defmodule Dragonex.Repo.Migrations.AddUserApiKeysAndGameAi do
  use Ecto.Migration

  # Players' own provider keys (encrypted, D242) and the AI each table plays
  # with, so a restart keeps the same model and payer.
  def change do
    create table(:user_api_keys) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:provider, :string, null: false)
      add(:ciphertext, :binary, null: false)
      add(:hint, :string, null: false)

      timestamps(type: :naive_datetime)
    end

    create(unique_index(:user_api_keys, [:user_id, :provider]))

    alter table(:games) do
      add(:ai, :map, null: false, default: %{})
    end
  end
end
