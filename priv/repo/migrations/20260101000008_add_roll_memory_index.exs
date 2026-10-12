defmodule Dragonex.Repo.Migrations.AddRollMemoryIndex do
  use Ecto.Migration

  def change do
    create(index(:game_events, [:game_id, :visible_to, :seq], where: "type = 'dice'"))
  end
end
