defmodule Dragonex.Repo.Migrations.AddDiceEngineToGames do
  use Ecto.Migration

  # Which dice render engine a partida uses: "2d" (canvas, server-authoritative)
  # or "3d" (Three.js + Rapier, physics-truth). Default "2d". The engine flag
  # lives per-partida so every viewer shares one authoritative roll.
  def change do
    alter table(:games) do
      add(:dice_engine, :string, default: "2d", null: false)
    end
  end
end
