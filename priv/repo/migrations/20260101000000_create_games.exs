defmodule Dragonex.Repo.Migrations.CreateGames do
  use Ecto.Migration

  def change do
    create table(:games) do
      add(:title, :string)
      add(:story_bible, :map, default: %{})
      add(:dm_style, :string, default: "vivid but brief")
      add(:world, :map)
      add(:status, :string, default: "configuring", null: false)
      add(:round, :integer, default: 1, null: false)
      add(:current_participant, :string)

      timestamps(type: :naive_datetime)
    end

    create table(:participants) do
      add(:game_id, references(:games, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:kind, :string, default: "human", null: false)
      add(:side, :string, default: "pc", null: false)

      timestamps(type: :naive_datetime)
    end

    create(index(:participants, [:game_id]))
    create(unique_index(:participants, [:game_id, :name]))

    create table(:characters) do
      add(:game_id, references(:games, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:sheet, :map, null: false)
      add(:kind, :string, default: "human", null: false)

      timestamps(type: :naive_datetime)
    end

    create(index(:characters, [:game_id]))
    create(unique_index(:characters, [:game_id, :name]))

    create table(:game_events) do
      add(:game_id, references(:games, on_delete: :delete_all), null: false)
      add(:seq, :integer, null: false)
      add(:type, :string, null: false)
      add(:actor, :string)
      add(:visible_to, :string, default: "all", null: false)
      add(:payload, :map, default: %{})

      add(:inserted_at, :naive_datetime, null: false)
    end

    create(index(:game_events, [:game_id, :seq]))
  end
end
