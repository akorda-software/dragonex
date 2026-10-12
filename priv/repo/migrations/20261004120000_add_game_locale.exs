defmodule Dragonex.Repo.Migrations.AddGameLocale do
  use Ecto.Migration

  # Each table plays in one language; existing games are Spanish.
  def change do
    alter table(:games) do
      add(:locale, :string, null: false, default: "es")
    end
  end
end
