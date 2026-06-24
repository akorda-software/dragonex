defmodule Dragones.Games.Game do
  @moduledoc """
  One persisted partida.

  The `world` column is the live `Dragones.World` serialized to jsonb through
  `Dragones.Codec` — the engine's working state (hp, initiative, phase). The
  Game process writes it after every change; rehydrating `Codec.decode(world)`
  rebuilds the world after a crash.

  `status` mirrors the Game process lifecycle:
  `:configuring | :running | :paused | :waiting | :ended`. `:waiting` is the
  human-turn idle state — the process is alive but no AI is acting.
  """

  use Ecto.Schema

  @type status :: :configuring | :running | :paused | :waiting | :ended

  schema "games" do
    field(:title, :string)
    field(:story_bible, :map, default: %{})
    field(:dm_style, :string, default: "vivid but brief")
    field(:dice_engine, :string, default: "2d")
    field(:world, :map)
    field(:status, Ecto.Enum,
      values: [:configuring, :running, :paused, :waiting, :ended],
      default: :configuring
    )
    field(:round, :integer, default: 1)
    field(:current_participant, :string)
    field(:intents, :map, default: %{})
    field(:open_slots, :integer, default: 0)

    belongs_to(:user, Dragones.Accounts.User)
    has_many(:participants, Dragones.Games.Participant)
    has_many(:characters, Dragones.Games.Character)
    has_many(:events, Dragones.Games.GameEvent)

    timestamps(type: :naive_datetime)
  end
end
