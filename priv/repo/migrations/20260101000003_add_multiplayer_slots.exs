defmodule Dragones.Repo.Migrations.AddMultiplayerSlots do
  use Ecto.Migration

  def change do
    alter table(:participants) do
      add(:user_id, references(:users, on_delete: :nilify_all))
    end

    create(index(:participants, [:user_id]))

    alter table(:games) do
      add(:open_slots, :integer, default: 0, null: false)
    end
  end
end
