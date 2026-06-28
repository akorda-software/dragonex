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
    dice_engine = Keyword.get(opts, :dice_engine, "2d")
    scene = Keyword.get(opts, :scene, "an unremarkable crossroads")
    roster = Keyword.get(opts, :roster, [])
    initiative = Keyword.get(opts, :initiative, [])
    user_id = Keyword.get(opts, :user_id)
    open_slots = Keyword.get(opts, :open_slots, 0)

    {world, participants, characters} = build_scenario(scene, roster, initiative, user_id)

    # Games with open slots start in :configuring (waiting room); others start
    # immediately in :running.
    initial_status = if open_slots > 0, do: :configuring, else: :running

    changeset =
      %Game{}
      |> Ecto.Changeset.cast(
        %{title: title, story_bible: story_bible, dm_style: dm_style, dice_engine: dice_engine, user_id: user_id, open_slots: open_slots},
        [:title, :story_bible, :dm_style, :dice_engine, :user_id, :open_slots]
      )
      |> Ecto.Changeset.put_change(:world, Dragones.Codec.encode(world))
      |> Ecto.Changeset.put_change(:status, initial_status)
      |> Ecto.Changeset.put_change(:current_participant, nil)
      |> Ecto.Changeset.put_assoc(:participants, participants)
      |> Ecto.Changeset.put_assoc(:characters, characters)

    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, game} ->
          # Seed the opening scene as the first timeline event.
          append_event(game.id, :system, "system", "all", %{note: "partida creada"})
          append_event(game.id, :narration, "dm", "all", %{text: opening_for(scene)})

          game

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Build a partida from the creator wizard's form params.

  `params` carries `title`, `scene`, `dm_style`, `user_id` (optional), and a
  `roster` map keyed by catalogue key OR hero id (prefixed `hero_`):
  `%{key => %{"include" => "on", "kind" => "human" | "ai"}}`. Catalogue entries
  resolve to their sheet builder; hero entries load the saved sheet from DB;
  monsters ignore `kind` (always DM-controlled). The partida opens in
  free-form exploration: combat starts only when the DM calls roll_initiative.
  """
  @spec create_from_wizard(map()) :: {:ok, Game.t()} | {:error, term()}
  def create_from_wizard(params) when is_map(params) do
    roster_params = Map.get(params, "roster") || %{}
    user_id = Map.get(params, "user_id")

    roster =
      roster_params
      |> Enum.filter(fn {_key, sel} -> Map.get(sel, "include") == "on" end)
      |> Enum.sort_by(fn {key, _} -> {monster_first?(key), key} end)
      |> Enum.map(fn {key, sel} ->
        {sheet, side} = resolve_roster_entry(key, user_id)
        kind = if side == "pc", do: parse_kind(Map.get(sel, "kind")), else: :ai
        {sheet, kind}
      end)

    if roster == [] do
      {:error, :no_characters}
    else
      # New games open in free-form exploration: the DM narrates the scene and
      # the players act, and combat begins naturally (the DM calls
      # roll_initiative) when a fight breaks out. Pre-baking combat at creation
      # left roll_initiative refusing "already in combat" and dropped players
      # into a fight before the scene was even set.
      create_game(
        title: Map.get(params, "title", "Nueva partida"),
        scene: scene_from(roster, Map.get(params, "scene")),
        story_bible: Map.get(params, "story_bible", %{}),
        dm_style: Map.get(params, "dm_style", "vivid but brief"),
        dice_engine: Map.get(params, "dice_engine", "2d"),
        roster: roster,
        initiative: [],
        user_id: user_id,
        open_slots: Map.get(params, "open_slots", 0)
      )
    end
  end

  defp resolve_roster_entry("hero_" <> id_str, user_id) do
    hero = Dragones.Accounts.get_hero(id_str)

    sheet =
      if hero do
        Dragones.Accounts.hero_sheet(hero)
      else
        nil
      end

    # Only allow importing the hero if it belongs to the user (or no user gate).
    cond do
      sheet == nil ->
        {Dragones.Archetypes.fighter(), "pc"}

      user_id != nil && hero.user_id != user_id ->
        {Dragones.Archetypes.fighter(), "pc"}

      true ->
        {sheet, "pc"}
    end
  end

  defp resolve_roster_entry(key, _user_id) do
    entry = Dragones.Scenario.catalog_entry(key)
    {entry.builder.(), entry.side}
  end

  defp parse_kind("ai"), do: :ai
  defp parse_kind(_), do: :human

  defp monster_first?(key), do: if(String.starts_with?(key, "hero_") or Dragones.Scenario.catalog_entry(key).side == "enemy", do: 0, else: 1)

  defp scene_from(_roster, nil), do: "an unremarkable crossroads"
  defp scene_from(_roster, ""), do: "an unremarkable crossroads"
  defp scene_from(_roster, scene), do: scene

  # Build the world + assoc structs from a roster of {character, kind} tuples.
  defp build_scenario(scene, roster, initiative, creator_user_id) do
    dm = struct(Participant, %{name: "dm", kind: :ai, side: "dm"})

    {participants, characters, add_fns} =
      roster
      |> Enum.reduce({[dm], [], []}, fn {sheet, kind}, {ps, cs, fs} ->
        c = struct(Character, %{name: sheet.name, sheet: sheet_to_map(sheet), kind: kind})

        # Only PCs are participants. The creator's PC (kind :human) gets the
        # creator's user_id so the viewer auto-assigns correctly.
        ps =
          if sheet.side == "pc" do
            p = struct(Participant, %{name: sheet.name, kind: kind, side: sheet.side})

            p =
              if kind == :human and creator_user_id,
                do: %{p | user_id: creator_user_id},
                else: p

            ps ++ [p]
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
      |> Dragones.World.init_spell_slots()
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

  defp opening_for(scene), do: "La escena está preparada: #{scene}."

  # --------------------------------------------------------------- reads

  @doc "Fetch a game with participants and characters preloaded."
  @spec get_game(term()) :: Game.t() | nil
  def get_game(id) do
    Repo.get(Game, id)
    |> Repo.preload([:participants, :characters])
  end

  @doc "Games for a user: created by them OR they're a participant. nil = all games."
  @spec list_games(term() | nil) :: [Game.t()]
  def list_games(nil) do
    Repo.all(from(g in Game, order_by: [desc: g.inserted_at], preload: [:participants]))
  end

  def list_games(user_id) do
    Repo.all(
      from(g in Game,
        where:
          g.user_id == ^user_id or
            g.id in subquery(from(p in Participant, where: p.user_id == ^user_id, select: p.game_id)),
        order_by: [desc: g.inserted_at],
        preload: [:participants]
      )
    )
  end

  @doc """
  A human player joins an open slot: creates a participant (linked to their
  user), adds the character to the live world (if running), and decrements
  `open_slots`. Returns `{:ok, game}` or `{:error, reason}`.
  """
  @spec join_game(Game.t(), Dragones.Accounts.User.t(), Dragones.Character.t()) ::
          {:ok, Game.t()} | {:error, term()}
  def join_game(%Game{id: game_id, open_slots: open} = _game, user, %Dragones.Character{} = sheet)
      when open > 0 do
    Repo.transaction(fn ->
      # Create the participant (linked to the user)
      {:ok, _participant} =
        %Participant{}
        |> Ecto.Changeset.cast(
          %{game_id: game_id, user_id: user.id, name: sheet.name, kind: :human, side: "pc"},
          [:game_id, :user_id, :name, :kind, :side]
        )
        |> Repo.insert()

      # Store the character sheet
      {:ok, _char} =
        %Character{}
        |> Ecto.Changeset.cast(
          %{game_id: game_id, name: sheet.name, sheet: sheet_to_map(sheet), kind: :human},
          [:game_id, :name, :sheet, :kind]
        )
        |> Repo.insert()

      # Add to the live world if the game is running
      game = get_game(game_id)

      if game.world do
        world = load_world(game)

        world =
          case Dragones.World.add_character(sheet).(world) do
            {:ok, w} -> w
            {:error, _} -> world
          end

        {:ok, _} =
          save_state(game_id, world, game.current_participant, game.round, game.status, game.intents || %{})
      end

      # Decrement open_slots
      {1, _} =
        Repo.update_all(
          from(g in Game, where: g.id == ^game_id),
          set: [open_slots: open - 1]
        )

      get_game(game_id)
    end)
  end

  def join_game(%Game{open_slots: 0}, _user, _sheet), do: {:error, :no_open_slots}

  @doc "Can the given user access this game (creator, participant, or open slots)?"
  @spec can_access?(Game.t(), Dragones.Accounts.User.t() | nil) :: boolean()
  def can_access?(%Game{user_id: uid}, %Dragones.Accounts.User{id: uid}), do: true

  def can_access?(%Game{} = game, %Dragones.Accounts.User{} = user) do
    game = Repo.preload(game, [:participants])

    Enum.any?(game.participants, fn p ->
      p.user_id == user.id
    end)
  end

  def can_access?(_, _), do: false

  @doc "Start a game from the waiting room: flip status to :running."
  @spec start_game(term()) :: {:ok, Game.t()} | {:error, term()}
  def start_game(game_id) do
    {:ok, _} = set_status(game_id, :running)
    {:ok, get_game(game_id)}
  end

  @doc "Games with open slots, excluding those owned by the user."
  @spec open_games(Dragones.Accounts.User.t()) :: [Game.t()]
  def open_games(%Dragones.Accounts.User{id: uid}) do
    Repo.all(
      from(g in Game,
        where: g.open_slots > 0 and g.user_id != ^uid and g.status in ^[:running, :waiting, :paused],
        order_by: [desc: g.inserted_at],
        preload: [:participants]
      )
    )
  end
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
  def recent_events(game_id, n \\ 200) do
    Repo.all(from(e in GameEvent, where: e.game_id == ^game_id, order_by: [desc: e.seq], limit: ^n))
    |> Enum.reverse()
  end

  @doc """
  Older events for pagination: the `n` events strictly before `before_seq`
  (i.e. with a lower seq), oldest-first. Used by the LiveView's "load more"
  handler to grow the chat timeline upward without re-fetching the whole log.
  """
  @spec events_before(term(), integer(), pos_integer()) :: [GameEvent.t()]
  def events_before(game_id, before_seq, n \\ 200) do
    Repo.all(
      from(e in GameEvent,
        where: e.game_id == ^game_id and e.seq < ^before_seq,
        order_by: [desc: e.seq],
        limit: ^n
      )
    )
    |> Enum.reverse()
  end

  @doc "Total event count for a game (drives the 'has more' flag in the UI)."
  @spec count_events(term()) :: non_neg_integer()
  def count_events(game_id) do
    Repo.one(from(e in GameEvent, where: e.game_id == ^game_id, select: count(e.id)))
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
