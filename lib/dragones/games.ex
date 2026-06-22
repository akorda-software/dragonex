defmodule Dragones.Games do
  @moduledoc """
  The persistence context for a Dragones partida.

  Owns every Postgres read/write. The `Dragones.Game` GenServer calls these to
  rehydrate on start and to persist after every beat (state + append-only
  events). Nothing else should touch the Repo directly for game data.

  Two layers of state, both durable:

    * `games.world` (jsonb via `Dragones.Codec`) — the live `Dragones.World`
      (hp, initiative, phase). Rebuilt into a struct by `Codec.decode/1`.
    * `game_events` (append-only) — the replayable timeline (narration, action,
      tool, dice, system), with a monotonic `seq` per game.
  """

  import Ecto.Query

  alias Dragones.Repo
  alias Dragones.Games.{Character, Game, GameEvent, Participant}

  # --------------------------------------------------------------- setup

  @doc """
  Create a partida from a scenario: a title, the campaign bible, a scene, and a
  list of *roster entries* — each a character sheet plus the participant that
  controls it (`kind: :ai | :human`). The DM participant is added automatically.

  The initial `Dragones.World` is built from the sheets (characters added, scene
  set), combat is begun with the given `initiative` order, and everything is
  persisted in one transaction. Returns the created `Game` row (id preloaded).
  """
  @spec create_game(keyword()) :: {:ok, Game.t()} | {:error, term()}
  def create_game(opts) do
    title = Keyword.get(opts, :title, "An Unremarkable Crossroads")
    story_bible = Keyword.get(opts, :story_bible, %{})
    dm_style = Keyword.get(opts, :dm_style, "vivid but brief")
    scene = Keyword.get(opts, :scene, "an unremarkable crossroads")
    roster = Keyword.get(opts, :roster, [])
    initiative = Keyword.get(opts, :initiative, [])

    {world, participants, characters} = build_scenario(scene, roster, initiative)

    changeset =
      %Game{}
      |> Ecto.Changeset.cast(
        %{title: title, story_bible: story_bible, dm_style: dm_style},
        [:title, :story_bible, :dm_style]
      )
      |> Ecto.Changeset.put_change(:world, Dragones.Codec.encode(world))
      |> Ecto.Changeset.put_change(:status, :running)
      |> Ecto.Changeset.put_change(:current_participant, nil)
      |> Ecto.Changeset.put_assoc(:participants, participants)
      |> Ecto.Changeset.put_assoc(:characters, characters)

    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, game} ->
          # Seed the opening scene as the first timeline event.
          append_event(game.id, :system, "system", "all", %{note: "game created"})
          append_event(game.id, :narration, "dm", "all", %{text: opening_for(scene)})

          game

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Build a partida from the creator wizard's form params.

  `params` carries `title`, `scene`, `dm_style`, and a `roster` map keyed by
  catalogue key: `%{key => %{"include" => "on", "kind" => "human" | "ai"}}`.
  Catalogue entries resolve to their sheet builder; monsters ignore `kind`
  (always DM-controlled). Combat begins when at least one monster AND one PC are
  picked, with monsters first in the order (so the DM auto-acts on open).
  """
  @spec create_from_wizard(map()) :: {:ok, Game.t()} | {:error, term()}
  def create_from_wizard(params) when is_map(params) do
    roster_params = Map.get(params, "roster") || %{}

    roster =
      roster_params
      |> Enum.filter(fn {_key, sel} -> Map.get(sel, "include") == "on" end)
      |> Enum.sort_by(fn {key, _} -> {monster_first?(key), key} end)
      |> Enum.map(fn {key, sel} ->
        entry = Dragones.Scenario.catalog_entry(key)
        kind = if entry.side == "pc", do: parse_kind(Map.get(sel, "kind")), else: :ai
        {entry.builder.(), kind}
      end)

    if roster == [] do
      {:error, :no_characters}
    else
      pc? = Enum.any?(roster, fn {%Dragones.Character{side: s}, _} -> s == "pc" end)
      monster? = Enum.any?(roster, fn {%Dragones.Character{side: s}, _} -> s == "enemy" end)

      initiative =
        if pc? and monster? do
          roster
          |> Enum.filter(fn {%Dragones.Character{side: s}, _} -> s == "enemy" end)
          |> Enum.map(fn {%Dragones.Character{name: n}, _} -> n end)
          |> Kernel.++(
            roster
            |> Enum.filter(fn {%Dragones.Character{side: s}, _} -> s == "pc" end)
            |> Enum.map(fn {%Dragones.Character{name: n}, _} -> n end)
          )
        else
          []
        end

      create_game(
        title: Map.get(params, "title", "Nueva partida"),
        scene: scene_from(roster, Map.get(params, "scene")),
        story_bible: %{},
        dm_style: Map.get(params, "dm_style", "vivid but brief"),
        roster: roster,
        initiative: initiative
      )
    end
  end

  defp parse_kind("ai"), do: :ai
  defp parse_kind(_), do: :human

  defp monster_first?(key), do: if(Dragones.Scenario.catalog_entry(key).side == "enemy", do: 0, else: 1)

  defp scene_from(_roster, nil), do: "an unremarkable crossroads"
  defp scene_from(_roster, ""), do: "an unremarkable crossroads"
  defp scene_from(_roster, scene), do: scene

  # Build the world + assoc structs from a roster of {character, kind} tuples.
  defp build_scenario(scene, roster, initiative) do
    dm = struct(Participant, %{name: "dm", kind: :ai, side: "dm"})

    {participants, characters, add_fns} =
      roster
      |> Enum.reduce({[dm], [], []}, fn {sheet, kind}, {ps, cs, fs} ->
        c = struct(Character, %{name: sheet.name, sheet: sheet_to_map(sheet), kind: kind})

        # Only PCs are participants (they act on their own turn). Monsters/NPCs
        # (side != "pc") are world characters the DM controls — the WorldDriven
        # policy folds them onto the DM's single turn, so they need no row here.
        ps =
          if sheet.side == "pc" do
            ps ++ [struct(Participant, %{name: sheet.name, kind: kind, side: sheet.side})]
          else
            ps
          end

        {ps, cs ++ [c], fs ++ [Dragones.World.add_character(sheet)]}
      end)

    world =
      add_fns
      |> Enum.reduce(Dragones.World.new(), fn change, w ->
        {:ok, nw} = change.(w)
        nw
      end)
      |> then(fn w -> {:ok, w2} = Dragones.World.set_scene(scene).(w); w2 end)
      |> then(fn w ->
        case initiative do
          [] -> w
          order -> {:ok, w3} = Dragones.World.begin_combat(order).(w); w3
        end
      end)

    {world, participants, characters}
  end

  # A Character sheet round-trips to a plain map for jsonb storage. We reuse the
  # Codec's per-field encoder so the baseline sheet matches the live world form.
  defp sheet_to_map(%Dragones.Character{} = c) do
    # Reuse the private codec by encoding a single-character world, then pulling
    # the entry out. Keeps one source of truth for the sheet shape.
    world = %Dragones.World{characters: %{c.name => c}}
    Dragones.Codec.encode(world)["characters"][c.name]
  end

  defp opening_for(scene), do: "The scene is set: #{scene}."

  # --------------------------------------------------------------- reads

  @doc "Fetch a game with participants and characters preloaded."
  @spec get_game(term()) :: Game.t() | nil
  def get_game(id) do
    Repo.get(Game, id)
    |> Repo.preload([:participants, :characters])
  end

  @doc "All games, newest first."
  @spec list_games() :: [Game.t()]
  def list_games do
    Repo.all(from(g in Game, order_by: [desc: g.inserted_at], preload: [:participants]))
  end

  @doc "Delete a game (cascades to participants/characters/events via on_delete)."
  @spec delete_game(term()) :: {:ok, Game.t()} | {:error, :not_found}
  def delete_game(id) do
    case Repo.get(Game, id) do
      nil -> {:error, :not_found}
      %Game{} = game -> {:ok, Repo.delete!(game)}
    end
  end

  @doc "Decode the persisted world jsonb back into a `Dragones.World` struct."
  @spec load_world(Game.t()) :: Dragones.World.t()
  def load_world(%Game{world: world}), do: Dragones.Codec.decode(world)

  @doc "The monotonic next seq for a game's event log."
  @spec next_seq(term()) :: non_neg_integer()
  def next_seq(game_id) do
    Repo.one(
      from(e in GameEvent,
        where: e.game_id == ^game_id,
        select: coalesce(max(e.seq), 0) + 1
      )
    )
  end

  @doc "The full append-only timeline for a game, in order."
  @spec list_events(term()) :: [GameEvent.t()]
  def list_events(game_id) do
    Repo.all(from(e in GameEvent, where: e.game_id == ^game_id, order_by: e.seq))
  end

  @doc "The last `n` events (for agent context / chat render)."
  @spec recent_events(term(), pos_integer()) :: [GameEvent.t()]
  def recent_events(game_id, n \\ 20) do
    Repo.all(from(e in GameEvent, where: e.game_id == ^game_id, order_by: [desc: e.seq], limit: ^n))
    |> Enum.reverse()
  end

  # --------------------------------------------------------------- writes

  @doc """
  Persist the live game state after a beat: the world (jsonb via Codec), whose
  turn it is, the round, the status, and the pending intents map. Called by the
  Game process after every turn advance.
  """
  @spec save_state(term(), Dragones.World.t(), String.t() | nil, integer(), atom(), map()) ::
          {:ok, Game.t()} | {:error, term()}
  def save_state(game_id, %Dragones.World{} = world, current, round, status, intents \\ %{}) do
    Repo.update_all(
      from(g in Game, where: g.id == ^game_id),
      set: [
        world: Dragones.Codec.encode(world),
        current_participant: current,
        round: round,
        status: to_string(status),
        intents: intents
      ]
    )

    {:ok, get_game(game_id)}
  end

  @doc "Persist only the pending intents map (called when a human declares off-turn)."
  @spec save_intents(term(), map()) :: {:ok, Game.t()} | {:error, term()}
  def save_intents(game_id, intents) do
    Repo.update_all(from(g in Game, where: g.id == ^game_id), set: [intents: intents])
    {:ok, get_game(game_id)}
  end

  @doc "Set only the status (e.g. :waiting, :paused, :running)."
  @spec set_status(term(), atom()) :: {:ok, Game.t()} | {:error, term()}
  def set_status(game_id, status) do
    Repo.update_all(from(g in Game, where: g.id == ^game_id), set: [status: to_string(status)])
    {:ok, get_game(game_id)}
  end

  @doc """
  Append an event to the timeline. `seq` is monotonic per game (computed in the
  same transaction). Returns the created event.
  """
  @spec append_event(term(), atom(), String.t() | nil, String.t(), map()) ::
          {:ok, GameEvent.t()} | {:error, term()}
  def append_event(game_id, type, actor, visible_to, payload) do
    %GameEvent{}
    |> Ecto.Changeset.cast(
      %{
        game_id: game_id,
        seq: next_seq(game_id),
        type: to_string(type),
        actor: actor,
        visible_to: visible_to,
        payload: payload
      },
      [:game_id, :seq, :type, :actor, :visible_to, :payload]
    )
    |> Repo.insert()
  end
end
