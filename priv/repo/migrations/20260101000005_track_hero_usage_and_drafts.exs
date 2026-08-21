defmodule Dragonex.Repo.Migrations.TrackHeroUsageAndDrafts do
  use Ecto.Migration

  def change do
    alter table(:heroes) do
      add(:draft, :map)
    end

    alter table(:characters) do
      add(:hero_id, references(:heroes, on_delete: :nilify_all))
    end

    create(index(:characters, [:hero_id]))
  end
end
