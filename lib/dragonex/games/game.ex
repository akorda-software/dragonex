defmodule Dragonex.Games.Game do
  @moduledoc """
  One persisted partida.

  The `world` column is the live `Dragonex.World` serialized to jsonb through
  `Dragonex.Codec` — the engine's working state (hp, initiative, phase). The
  Game process writes it after every change; rehydrating `Codec.decode(world)`
  rebuilds the world after a crash.

  `status` mirrors the Game process lifecycle:
  `:configuring | :running | :paused | :waiting | :ended`. `:waiting` is the
  human-turn idle state — the process is alive but no AI is acting.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @title_limit 255
  def title_limit, do: @title_limit

  @doc "Validate creation metadata before it reaches database string limits."
  def creation_changeset(game, attrs) do
    game
    |> cast(attrs, [:title, :story_bible, :dm_style, :dice_engine, :user_id, :open_slots, :locale])
    |> validate_inclusion(:locale, ~w(es en))
    |> validate_length(:title, max: @title_limit, count: :codepoints)
  end

  @type status :: :configuring | :running | :paused | :waiting | :ended

  schema "games" do
    field(:title, :string)
    field(:story_bible, :map, default: %{})
    field(:dm_style, :string, default: "vivid but brief")
    field(:dice_engine, :string, default: "2d")
    field(:locale, :string, default: "es")
    field(:world, :map)

    field(:status, Ecto.Enum,
      values: [:configuring, :running, :paused, :waiting, :ended],
      default: :configuring
    )

    field(:round, :integer, default: 1)
    field(:current_participant, :string)
    field(:intents, :map, default: %{})
    field(:open_slots, :integer, default: 0)
    # Which AI plays this table and who pays for it (D242), see Dragonex.GameAI.
    field(:ai, :map, default: %{})

    belongs_to(:user, Dragonex.Accounts.User)
    has_many(:participants, Dragonex.Games.Participant)
    has_many(:characters, Dragonex.Games.Character)
    has_many(:events, Dragonex.Games.GameEvent)

    timestamps(type: :naive_datetime)
  end
end
