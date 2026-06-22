defmodule Dragones.Repo.Migrations.AddIntentsToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      # Pending declared intents: %{participant_name => text}. A human can declare
      # an action anytime (even off-turn); the Game consumes it when their turn
      # arrives. Durable so a restart doesn't lose a player's plan.
      add(:intents, :map, default: %{})
    end
  end
end
