defmodule Dragones.Repo.Migrations.CreateCustomContents do
  use Ecto.Migration

  def change do
    create table(:custom_contents) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:key, :string, null: false)
      add(:name_es, :string, null: false)
      add(:definition, :map, null: false)
      add(:notes, :string)

      timestamps(type: :naive_datetime)
    end

    # Una key estable por usuario y tipo (slug lowercased).
    create(unique_index(:custom_contents, [:user_id, :kind, :key]))
    create(index(:custom_contents, [:user_id, :kind]))
  end
end
