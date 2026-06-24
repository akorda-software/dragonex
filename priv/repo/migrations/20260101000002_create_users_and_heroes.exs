defmodule Dragones.Repo.Migrations.CreateUsersAndHeroes do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:email, :string, null: false)
      add(:password_hash, :string, null: false)
      add(:display_name, :string, null: false)

      timestamps(type: :naive_datetime)
    end

    create(unique_index(:users, [:email]))

    # A hero is a character template owned by a user — the output of the
    # character creator. The `sheet` column holds the Character via Codec.encode.
    create table(:heroes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:race, :string, null: false)
      add(:class, :string, null: false)
      add(:level, :integer, default: 1, null: false)
      add(:sheet, :map, null: false)

      timestamps(type: :naive_datetime)
    end

    create(index(:heroes, [:user_id]))

    # Games belong to the user who created them.
    alter table(:games) do
      add(:user_id, references(:users, on_delete: :nilify_all))
    end

    create(index(:games, [:user_id]))
  end
end
