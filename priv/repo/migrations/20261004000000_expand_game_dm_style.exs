defmodule Dragonex.Repo.Migrations.ExpandGameDMStyle do
  use Ecto.Migration

  def change do
    alter table(:games) do
      modify(:dm_style, :text, from: :string)
    end
  end
end
