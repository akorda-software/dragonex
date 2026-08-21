defmodule Dragonex.Repo.Migrations.AddUniqueSeqAndParticipantIndexes do
  use Ecto.Migration

  def up do
    # game_events.seq is meant to be monotonic per game. The app computes it
    # non-atomically (next_seq = max+1); enforce the invariant at the DB level so
    # parallel tool roll-closes can't produce duplicate/out-of-order timeline
    # entries.
    drop(index(:game_events, [:game_id, :seq]))
    create(unique_index(:game_events, [:game_id, :seq]))

    # A user should not be able to join the same partida twice. Postgres treats
    # NULLs as distinct, so AI/DM participants (user_id IS NULL) are unaffected.
    create(unique_index(:participants, [:game_id, :user_id]))
  end

  def down do
    drop(unique_index(:participants, [:game_id, :user_id]))

    drop(unique_index(:game_events, [:game_id, :seq]))
    create(index(:game_events, [:game_id, :seq]))
  end
end
