defmodule Dragonex.Repo.Migrations.AddGoogleSignIn do
  use Ecto.Migration

  # Sign in with Google (D245): the account remembers Google's stable subject
  # id, and an account created through Google has no password of its own.
  def change do
    alter table(:users) do
      add(:google_sub, :string)
      modify(:password_hash, :string, null: true, from: {:string, null: false})
    end

    create(unique_index(:users, [:google_sub]))
  end
end
