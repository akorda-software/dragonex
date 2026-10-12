defmodule Dragonex.Games do
  @moduledoc """
  The persistence context for a Dragonex partida.

  Owns every Postgres read/write. The `Dragonex.Game` GenServer calls these to
  rehydrate on start and to persist after every beat (state + append-only
  events). Nothing else should touch the Repo directly for game data.

  Two layers of state, both durable:

    * `games.world` (jsonb via `Dragonex.Codec`) — the live `Dragonex.World`
      (hp, initiative, phase). Rebuilt into a struct by `Codec.decode/1`.
    * `game_events` (append-only) — the replayable timeline (narration, action,
      tool, dice, system), with a monotonic `seq` per game.
  """

  import Ecto.Query
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Repo
  alias Dragonex.Games.{Character, Game, GameEvent, Participant}

  # --------------------------------------------------------------- setup

  @doc """
  Create a partida from a scenario: a title, the campaign bible, a scene, and a
  list of *roster entries* — each a character sheet plus the participant that
  controls it (`kind: :ai | :human`). The DM participant is added automatically.

  The initial `Dragonex.World` is built from the sheets (characters added, scene
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
    locale = opts |> Keyword.get(:locale, Dragonex.I18n.locale()) |> Dragonex.I18n.normalize()

    # Bible facts are seeded in the game's own language.
    {world, participants, characters} =
      Dragonex.I18n.with_locale(locale, fn ->
        build_scenario(scene, roster, initiative, user_id, story_bible || %{})
      end)

    # Games with open slots start in :configuring (waiting room); others start
    # immediately in :running.
    initial_status = if open_slots > 0, do: :configuring, else: :running

    changeset =
      %Game{}
      |> Game.creation_changeset(%{
        title: title,
        story_bible: story_bible,
        dm_style: dm_style,
        dice_engine: dice_engine,
        user_id: user_id,
        open_slots: open_slots,
        locale: Atom.to_string(locale)
      })
      |> Ecto.Changeset.put_change(:world, Dragonex.Codec.encode(world))
      |> Ecto.Changeset.put_change(:status, initial_status)
      |> Ecto.Changeset.put_change(:current_participant, nil)
      |> Ecto.Changeset.put_assoc(:participants, participants)
      |> Ecto.Changeset.put_assoc(:characters, characters)

    if changeset.valid? do
      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, game} ->
            # Seed the opening scene as the first timeline event, written in
            # the game's own language.
            Dragonex.I18n.with_locale(locale, fn ->
              append_event(game.id, :system, "system", "all", %{
                note: dgettext("engine", "partida creada")
              })

              append_event(game.id, :narration, "dm", "all", %{text: opening_for(scene)})
            end)

            game

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
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
        {sheet, side, hero_id} = resolve_roster_entry(key, user_id)
        kind = if side == "pc", do: parse_kind(Map.get(sel, "kind")), else: :ai
        {sheet, kind, hero_id}
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
        title: Map.get(params, "title", dgettext("ui", "Nueva partida")),
        scene: scene_from(roster, Map.get(params, "scene")),
        story_bible: Map.get(params, "story_bible", %{}),
        dm_style: Map.get(params, "dm_style", "vivid but brief"),
        dice_engine: Map.get(params, "dice_engine", "2d"),
        roster: roster,
        initiative: [],
        user_id: user_id,
        open_slots: Map.get(params, "open_slots", 0),
        locale: Map.get(params, "locale", Dragonex.I18n.locale())
      )
    end
  end

  @doc """
  Build a partida directly from the creator wizard's semantic selections:
  `:scenario` (a `Scenarios` entry, `%{key: "custom"}`, or `nil`), `:my_hero`
  (the user's chosen hero key), `:companions` (the per-slot list, where
  `"open"` reserves a human slot), `:dice_engine`, `:user_id`, and the optional
  `:custom_title` / `:custom_scene` / `:custom_dm_style` for custom scenarios.

  This owns the scenario-field resolution and the roster assembly so the
  LiveView stays a thin forwarder. Delegates roster parsing + persistence to
  `create_from_wizard/1`.
  """
  @spec create_from_wizard_choices(map()) :: {:ok, Game.t()} | {:error, term()}
  def create_from_wizard_choices(choices) do
    locale = choices |> Map.get(:locale, Dragonex.I18n.locale()) |> Dragonex.I18n.normalize()

    # The picked scenario arrives resolved in the UI's language; the game's
    # bible, title and scene must be written in the GAME's language (D236).
    {bible, title, scene, dm_style} =
      Dragonex.I18n.with_locale(locale, fn ->
        choices |> relocalize_scenario() |> resolve_scenario_fields()
      end)

    companions = Map.get(choices, :companions, [])
    open_count = Enum.count(companions, &(&1 == "open"))
    roster = build_wizard_roster(Map.get(choices, :my_hero), companions)

    create_from_wizard(%{
      "title" => title,
      "scene" => scene,
      "dm_style" => dm_style,
      "story_bible" => bible,
      "dice_engine" => Map.get(choices, :dice_engine, "2d"),
      "user_id" => Map.get(choices, :user_id),
      "roster" => roster,
      "open_slots" => open_count,
      "locale" => locale
    })
  end

  # Re-resolve a catalog scenario by key in the active locale; a custom (or
  # unknown) scenario keeps whatever the wizard collected.
  defp relocalize_scenario(%{scenario: %{key: key} = scenario} = choices)
       when is_binary(key) and key != "custom" do
    %{choices | scenario: Dragonex.Scenarios.get(key) || scenario}
  end

  defp relocalize_scenario(choices), do: choices

  @doc "Validate wizard details without writing a game or resolving its roster."
  def wizard_details_changeset(choices) do
    locale = choices |> Map.get(:locale, Dragonex.I18n.locale()) |> Dragonex.I18n.normalize()

    {bible, title, _scene, dm_style} =
      Dragonex.I18n.with_locale(locale, fn ->
        choices |> relocalize_scenario() |> resolve_scenario_fields()
      end)

    Game.creation_changeset(%Game{}, %{title: title, story_bible: bible, dm_style: dm_style})
  end

  def creation_title_limit, do: Game.title_limit()

  # Scenario → {bible, title, scene, dm_style}. A custom scenario (or none) falls
  # back to the wizard's custom_* fields then to safe defaults; a picked scenario
  # contributes its own bible + fields.
  defp resolve_scenario_fields(%{scenario: %{key: "custom"}} = ch) do
    {%{}, Map.get(ch, :custom_title) || dgettext("ui", "Nueva partida"),
     Map.get(ch, :custom_scene) || "an unremarkable crossroads",
     Map.get(ch, :custom_dm_style) || "vivid but brief"}
  end

  defp resolve_scenario_fields(%{scenario: nil}) do
    {%{}, dgettext("ui", "Nueva partida"), "an unremarkable crossroads", "vivid but brief"}
  end

  defp resolve_scenario_fields(%{scenario: scenario}) do
    {Dragonex.Scenarios.bible(scenario), scenario.title, scenario.scene, scenario.dm_style}
  end

  # Assemble the roster input `create_from_wizard/1` expects: the user's hero as
  # `:human`, each companion slot as `:ai` (skipping nil / "open"), with duplicate
  # keys disambiguated by slot index.
  defp build_wizard_roster(my_hero, companions) do
    roster = if my_hero, do: %{my_hero => %{"include" => "on", "kind" => "human"}}, else: %{}

    companions
    |> Enum.with_index()
    |> Enum.reduce(roster, fn {key, idx}, acc ->
      cond do
        key == nil or key == "open" ->
          acc

        Map.has_key?(acc, key) ->
          Map.put(acc, "#{key}_#{idx}", %{"include" => "on", "kind" => "ai"})

        true ->
          Map.put(acc, key, %{"include" => "on", "kind" => "ai"})
      end
    end)
  end

  defp resolve_roster_entry("hero_" <> id_str, user_id) do
    hero = Dragonex.Accounts.get_hero(id_str)

    sheet =
      if hero do
        Dragonex.Accounts.hero_sheet(hero)
      else
        nil
      end

    # Only allow importing the hero if it belongs to the user (or no user gate).
    cond do
      sheet == nil ->
        {Dragonex.Archetypes.fighter(), "pc", nil}

      user_id != nil && hero.user_id != user_id ->
        {Dragonex.Archetypes.fighter(), "pc", nil}

      true ->
        {sheet, "pc", hero.id}
    end
  end

  defp resolve_roster_entry(key, _user_id) do
    entry = Dragonex.Roster.catalog_entry(key)
    {entry.builder.(), entry.side, nil}
  end

  defp parse_kind("ai"), do: :ai
  defp parse_kind(_), do: :human

  defp monster_first?(key),
    do:
      if(String.starts_with?(key, "hero_") or Dragonex.Roster.catalog_entry(key).side == "enemy",
        do: 0,
        else: 1
      )

  defp scene_from(_roster, nil), do: "an unremarkable crossroads"
  defp scene_from(_roster, ""), do: "an unremarkable crossroads"
  defp scene_from(_roster, scene), do: scene

  # Build the world + assoc structs from a roster of {character, kind} tuples.
  defp build_scenario(scene, roster, initiative, creator_user_id, story_bible) do
    dm = struct(Participant, %{name: "dm", kind: :ai, side: "dm"})

    {participants, characters, add_fns} =
      roster
      |> Enum.reduce({[dm], [], []}, fn entry, {ps, cs, fs} ->
        {sheet, kind, hero_id} = normalize_roster_entry(entry)

        c =
          struct(Character, %{
            name: sheet.name,
            sheet: Dragonex.Codec.encode_character(sheet),
            kind: kind,
            hero_id: hero_id
          })

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

        {ps, cs ++ [c], fs ++ [Dragonex.World.add_character(sheet)]}
      end)

    world =
      add_fns
      |> Enum.reduce(Dragonex.World.new(), fn change, w ->
        {:ok, nw} = change.(w)
        nw
      end)
      |> Dragonex.World.init_spell_slots()
      |> then(fn w ->
        {:ok, w2} = Dragonex.World.set_scene(scene).(w)
        w2
      end)
      |> then(fn w ->
        case initiative do
          [] ->
            w

          order ->
            {:ok, w3} = Dragonex.World.begin_combat(order).(w)
            w3
        end
      end)
      |> seed_bible_facts(story_bible)

    {world, participants, characters}
  end

  defp normalize_roster_entry({sheet, kind, hero_id}), do: {sheet, kind, hero_id}
  defp normalize_roster_entry({sheet, kind}), do: {sheet, kind, nil}

  defp seed_bible_facts(world, bible) do
    Enum.reduce(Dragonex.Scenarios.seed_facts(bible), world, fn fact, w ->
      {:ok, next} = Dragonex.World.add_fact(fact).(w)
      next
    end)
  end

  # The scene usually ends its own sentence; never print "harina..".
  defp opening_for(scene) do
    scene = String.trim(scene)

    scene = if String.ends_with?(scene, [".", "!", "?", "…"]), do: scene, else: scene <> "."
    dgettext("engine", "La escena está preparada: %{scene}", scene: scene)
  end

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
            g.id in subquery(
              from(p in Participant, where: p.user_id == ^user_id, select: p.game_id)
            ),
        order_by: [desc: g.inserted_at],
        preload: [:participants]
      )
    )
  end

  @doc """
  A human player joins an open slot of a game STILL IN CONFIGURATION (the
  waiting room): creates a participant (linked to their user), adds the
  character to the configuring world and decrements `open_slots` atomically.
  Returns `{:ok, game}` or `{:error, reason}` — `{:error, :already_started}`
  once the partida has started (start_game closes the door), `:already_joined`
  for a repeat join, `:no_open_slots` when the room is full and `:name_taken`
  for an ambiguous identity. The passed row may be stale: lock and reread it.
  """
  @spec join_game(Game.t(), Dragonex.Accounts.User.t(), Dragonex.Character.t(), keyword()) ::
          {:ok, Game.t()} | {:error, term()}
  def join_game(game, user, sheet, opts \\ [])

  def join_game(%Game{id: game_id}, user, %Dragonex.Character{} = sheet, opts) do
    hero_id = Keyword.get(opts, :hero_id)

    Repo.transaction(fn ->
      game = locked_game(game_id)
      world = load_world(game)

      cond do
        game.status != :configuring ->
          Repo.rollback(:already_started)

        Enum.any?(game.participants, &(&1.user_id == user.id)) ->
          Repo.rollback(:already_joined)

        game.open_slots <= 0 ->
          Repo.rollback(:no_open_slots)

        sheet.side != "pc" or not is_binary(sheet.name) or String.trim(sheet.name) == "" ->
          Repo.rollback(:invalid_character)

        join_name_taken?(game, world, sheet.name) ->
          Repo.rollback(:name_taken)

        true ->
          :ok
      end

      world =
        case Dragonex.World.add_character(sheet).(world) do
          {:ok, world} -> world
          {:error, _} -> Repo.rollback(:invalid_character)
        end

      # Create the participant (linked to the user)
      case %Participant{}
           |> Ecto.Changeset.cast(
             %{game_id: game_id, user_id: user.id, name: sheet.name, kind: :human, side: "pc"},
             [:game_id, :user_id, :name, :kind, :side]
           )
           |> Ecto.Changeset.unique_constraint([:game_id, :user_id], error_key: :user_id)
           |> Ecto.Changeset.unique_constraint([:game_id, :name], error_key: :name)
           |> Repo.insert() do
        {:ok, _participant} ->
          :ok

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :name),
            do: Repo.rollback(:name_taken),
            else: Repo.rollback(:already_joined)
      end

      # Store the character sheet
      {:ok, _char} =
        %Character{}
        |> Ecto.Changeset.cast(
          %{
            game_id: game_id,
            hero_id: hero_id,
            name: sheet.name,
            sheet: Dragonex.Codec.encode_character(sheet),
            kind: :human
          },
          [:game_id, :hero_id, :name, :sheet, :kind]
        )
        |> Repo.insert()

      # Configuring only, before the Game loop starts. Once started, World is
      # owned by the Game GenServer and this transaction rejects any join.
      game
      |> Ecto.Changeset.change(
        world: Dragonex.Codec.encode(world),
        open_slots: game.open_slots - 1
      )
      |> Repo.update!()

      get_game(game_id)
    end)
  end

  defp locked_game(game_id) do
    case Repo.one(from(g in Game, where: g.id == ^game_id, lock: "FOR UPDATE")) do
      nil -> Repo.rollback(:not_found)
      game -> Repo.preload(game, [:participants, :characters])
    end
  end

  defp join_name_taken?(game, world, name) do
    normalized = name |> String.trim() |> String.downcase()
    names = Enum.map(game.participants, & &1.name) ++ Map.keys(world.characters)
    Enum.any?(names, &(String.downcase(String.trim(&1)) == normalized))
  end

  @doc "Can the given user access this game (creator, participant, or open slots)?"
  @spec can_access?(Game.t(), Dragonex.Accounts.User.t() | nil) :: boolean()
  def can_access?(%Game{user_id: uid}, %Dragonex.Accounts.User{id: uid}), do: true

  def can_access?(%Game{} = game, %Dragonex.Accounts.User{} = user) do
    game = Repo.preload(game, [:participants])

    Enum.any?(game.participants, fn p ->
      p.user_id == user.id
    end)
  end

  def can_access?(_, _), do: false

  @doc """
  Start a game from the waiting room: flip status to :running and close the
  lobby — `open_slots` goes to 0 so no residual slot can list/join a partida
  that already started.
  """
  @spec start_game(term()) :: {:ok, Game.t()} | {:error, term()}
  def start_game(game_id) do
    Repo.transaction(fn ->
      game = locked_game(game_id)

      if game.status == :configuring do
        game
        |> Ecto.Changeset.change(status: :running, open_slots: 0)
        |> Repo.update!()
      end

      get_game(game_id)
    end)
  end

  @doc """
  Joinable games in the lobby: still `:configuring` (waiting room) with open
  slots, excluding those owned by the user. Running/paused partidas never
  list here — even with residual slots.
  """
  @spec open_games(Dragonex.Accounts.User.t()) :: [Game.t()]
  def open_games(%Dragonex.Accounts.User{id: uid}) do
    Repo.all(
      from(g in Game,
        where: g.open_slots > 0 and g.user_id != ^uid and g.status == :configuring,
        order_by: [desc: g.inserted_at],
        preload: [:participants]
      )
    )
  end

  @spec delete_game(Dragonex.Accounts.User.t(), term()) ::
          {:ok, Game.t()} | {:error, :not_found | :forbidden}
  def delete_game(%Dragonex.Accounts.User{id: uid}, id) do
    case Repo.get(Game, id) do
      nil -> {:error, :not_found}
      %Game{user_id: ^uid} = game -> {:ok, Repo.delete!(game)}
      %Game{} -> {:error, :forbidden}
    end
  end

  @doc "Decode the persisted world jsonb back into a `Dragonex.World` struct."
  @spec load_world(Game.t()) :: Dragonex.World.t()
  def load_world(%Game{world: world}), do: Dragonex.Codec.decode(world)

  @doc "IDs de partidas que usan un héroe concreto (vía `Characters.hero_id`)."
  @spec games_using_hero(term()) :: [term()]
  def games_using_hero(hero_id) do
    Repo.all(
      from(c in Character,
        where: c.hero_id == ^hero_id,
        select: c.game_id,
        distinct: true
      )
    )
  end

  @doc """
  Sincroniza una subida de nivel del héroe al `Character` vivo de una partida.

  Aplica los deltas (nivel, max_hp, vitalidad retroactiva de CON, atributos ASI,
  hechizos nuevos, class_features, xp) **sin pisar** el estado transitorio del
  combate (hp actual dañado, condiciones, death_saves, temp_hp, concentrating, raging, reckless, second_wind_used, action_surge_used, smite_slot, lay_on_hands_pool, divine_sense_uses, channel_divinity_used, ki, sorcery_points, bardic_inspiration_uses, inspired, arcane_recovery_used, wild_shape_uses, wild_shape, slots usados):
  subir de nivel no cura (RAW). Pools finitos ganan solo capacidad nueva según
  clase/nivel/Carisma, conservando lo gastado (D126). También actualiza el
  snapshot `characters.sheet`.

  En Forma salvaje progresa la ficha original guardada y conserva el estado
  físico/PG de la bestia; revertir recupera la forma original progresada (D129).

  Las partidas iniciadas se sincronizan siempre por su único `Game`, que se
  rehidrata si no está activo. Solo una sala aún `:configuring` se modifica en
  esta transacción, bloqueando/releyendo la fila frente al inicio de partida.
  Una ficha anterior al nivel vivo devuelve `:stale_level` sin cambios.
  """
  @spec sync_hero_level_up(term(), term(), Dragonex.Character.t()) ::
          {:ok, Game.t()} | {:error, :not_found | term()}
  def sync_hero_level_up(game_id, hero_id, %Dragonex.Character{} = new_sheet) do
    result =
      Repo.transaction(fn ->
        game = locked_game(game_id)

        if game.status != :configuring or not is_nil(Dragonex.Game.Supervisor.whereis(game.id)) do
          Repo.rollback({:game_started, game.id})
        end

        gc = Enum.find(game.characters, &(&1.hero_id == hero_id))
        if is_nil(gc), do: Repo.rollback(:not_found)
        world = load_world(game)
        live = world.characters[gc.name]
        if is_nil(live), do: Repo.rollback(:not_found)
        if new_sheet.level < live.level, do: Repo.rollback(:stale_level)
        world = merge_character_level_up(world, gc.name, new_sheet)

        gc
        |> Ecto.Changeset.change(sheet: Dragonex.Codec.encode_character(new_sheet))
        |> Repo.update!()

        game
        |> Ecto.Changeset.change(world: Dragonex.Codec.encode(world))
        |> Repo.update!()

        get_game(game.id)
      end)

    case result do
      {:error, {:game_started, id}} -> sync_started_hero(id, hero_id, new_sheet)
      other -> other
    end
  end

  defp sync_started_hero(game_id, hero_id, sheet) do
    started =
      case Dragonex.Game.ensure_started(game_id) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end

    with {:ok, pid} <- started,
         :ok <- Dragonex.Game.sync_hero_level_up(pid, hero_id, sheet) do
      {:ok, get_game(game_id)}
    end
  end

  @doc """
  Merge puro de una subida de nivel sobre el `Character` vivo de un `World`.
  Aplica los deltas (nivel, max_hp, vitalidad retroactiva de CON, atributos,
  spells, features, xp) sin pisar el estado transitorio: subir de nivel no cura
  (RAW 5e). Público para que el `Game` GenServer lo use dentro de un
  `Session.update_state` (single-writer).
  """
  @spec merge_character_level_up(Dragonex.World.t(), String.t(), Dragonex.Character.t()) ::
          Dragonex.World.t()
  def merge_character_level_up(world, name, %Dragonex.Character{} = new_sheet),
    do: do_merge_character_level_up(world, name, new_sheet)

  @doc "Actualiza el snapshot `characters.sheet` del héroe en una partida."
  @spec update_character_sheet(term(), term(), Dragonex.Character.t()) ::
          {:ok, term()}
  def update_character_sheet(game_id, hero_id, %Dragonex.Character{} = sheet) do
    {count, _} =
      Repo.update_all(
        from(c in Character, where: c.game_id == ^game_id and c.hero_id == ^hero_id),
        set: [sheet: Dragonex.Codec.encode_character(sheet)]
      )

    {:ok, count}
  end

  defp do_merge_character_level_up(world, name, new_sheet) do
    case world.characters[name] do
      nil ->
        world

      live when new_sheet.level < live.level ->
        world

      live ->
        active = live
        live = Dragonex.WildShape.base_form(live)

        # RAW 5e: subir de nivel NO cura. El `hp_gain` del nuevo nivel ya está en
        # `new_sheet.max_hp` pero NO se suma al hp actual. La única excepción es
        # la vitalidad retroactiva por subir el mod de CON (regla del PHB), que
        # sí aumenta el hp actual. Así un personaje dañado conserva su daño y un
        # caído (0 hp) sin ASI de CON sigue caído tras subir.
        old_con_mod = Dragonex.Rules.Ability.modifier(live.con)
        new_con_mod = Dragonex.Rules.Ability.modifier(new_sheet.con)
        con_retro = (new_con_mod - old_con_mod) * live.level

        merged =
          %{
            live
            | level: new_sheet.level,
              max_hp: new_sheet.max_hp,
              hp: max(0, live.hp + con_retro),
              xp: new_sheet.xp,
              ac: new_sheet.ac,
              str: new_sheet.str,
              dex: new_sheet.dex,
              con: new_sheet.con,
              int: new_sheet.int,
              wis: new_sheet.wis,
              cha: new_sheet.cha,
              spells: new_sheet.spells,
              class_features: new_sheet.class_features
          }

        merged = Dragonex.ClassResources.level_up(live, merged)
        merged = Dragonex.WildShape.preserve_form(merged, active)
        world = %{world | characters: Map.put(world.characters, name, merged)}

        slots =
          Dragonex.SpellSlots.level_up(
            live.class,
            live.level,
            merged.level,
            Map.get(world.spell_slots, name)
          )

        if slots != %{},
          do: %{world | spell_slots: Map.put(world.spell_slots, name, slots)},
          else: world
    end
  end

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
    Repo.all(
      from(e in GameEvent, where: e.game_id == ^game_id, order_by: [desc: e.seq], limit: ^n)
    )
    |> Enum.reverse()
  end

  @doc "Up to 32 older dice events for a role, filtered before the bound and returned oldest-first."
  @spec rolls_before(term(), pos_integer(), String.t() | nil, pos_integer()) :: [GameEvent.t()]
  def rolls_before(game_id, before_seq, viewer \\ nil, n \\ 32)
      when is_integer(before_seq) and before_seq > 0 and is_integer(n) and n > 0 do
    visibility = if viewer == "dm", do: ["all", "dm"], else: ["all"]
    limit = min(n, 32)

    Repo.all(
      from(e in GameEvent,
        where:
          e.game_id == ^game_id and e.type == :dice and e.seq < ^before_seq and
            e.visible_to in ^visibility,
        order_by: [desc: e.seq],
        limit: ^limit
      )
    )
    |> Enum.reverse()
  end

  @doc "Recent turn markers, unaffected by the number of tool or narration events."
  @spec recent_turns(term(), pos_integer()) :: [GameEvent.t()]
  def recent_turns(game_id, n \\ 64) do
    Repo.all(
      from(e in GameEvent,
        where: e.game_id == ^game_id and e.type == :turn,
        order_by: [desc: e.seq],
        limit: ^n
      )
    )
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
  @spec save_state(term(), Dragonex.World.t(), String.t() | nil, integer(), atom(), map()) ::
          {:ok, Game.t()} | {:error, term()}
  def save_state(game_id, %Dragonex.World{} = world, current, round, status, intents \\ %{}) do
    Repo.update_all(
      from(g in Game, where: g.id == ^game_id),
      set: [
        world: Dragonex.Codec.encode(world),
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
    do_append_event(game_id, type, actor, visible_to, payload, 4)
  end

  defp do_append_event(_game_id, _type, _actor, _visible_to, _payload, 0),
    do: {:error, :seq_conflict}

  defp do_append_event(game_id, type, actor, visible_to, payload, retries) do
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
    |> Ecto.Changeset.unique_constraint([:game_id, :seq])
    |> Repo.insert()
    |> case do
      {:ok, _} = ok ->
        ok

      {:error, %Ecto.Changeset{errors: errors}} when retries > 1 ->
        if Keyword.has_key?(errors, :seq) do
          do_append_event(game_id, type, actor, visible_to, payload, retries - 1)
        else
          {:error, :insert_failed}
        end

      {:error, _} ->
        {:error, :insert_failed}
    end
  end

  @doc "The public human declaration belonging to this exact durable actor turn."
  def declaration_for_turn(game_id, actor, turn_id) do
    payload =
      Repo.one(
        from(e in GameEvent,
          where:
            e.game_id == ^game_id and e.type == :action and e.actor == ^actor and
              e.visible_to == "all" and fragment("?->>'turn_id' = ?", e.payload, ^turn_id),
          order_by: [desc: e.seq],
          limit: 1,
          select: e.payload
        )
      )

    case payload do
      %{"text" => text} when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  @doc "True when this actor turn already paused once after a hard failure (D228)."
  def turn_retained?(game_id, turn_id) when is_binary(turn_id) do
    Repo.exists?(
      from(e in GameEvent,
        where:
          e.game_id == ^game_id and e.type == :system and
            fragment("?->>'turn_id' = ?", e.payload, ^turn_id) and
            fragment("?->>'kind' = 'turn_retained'", e.payload)
      )
    )
  end

  def turn_retained?(_game_id, _turn_id), do: false

  @doc """
  Read a completed actor response for recovery of the same pending beat.
  Intermediate, truncated and legacy narrations are not completion receipts.
  """
  def completed_narration(game_id, actor, turn_id) do
    payload =
      Repo.one(
        from(e in GameEvent,
          where:
            e.game_id == ^game_id and e.type == :narration and e.actor == ^actor and
              fragment("?->>'turn_id' = ?", e.payload, ^turn_id) and
              fragment("?->'complete' = 'true'::jsonb", e.payload),
          order_by: [desc: e.seq],
          limit: 1,
          select: e.payload
        )
      )

    case payload do
      %{"text" => text} when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  @doc "Public unfinished speech from this exact actor beat; it never proves completion."
  def intermediate_narration?(game_id, actor, turn_id) do
    Repo.exists?(
      from(e in GameEvent,
        where:
          e.game_id == ^game_id and e.type == :narration and e.actor == ^actor and
            e.visible_to == "all" and
            fragment("?->>'turn_id' = ?", e.payload, ^turn_id) and
            fragment("?->'complete' = 'false'::jsonb", e.payload) and
            fragment("jsonb_typeof(?->'text') = 'string'", e.payload) and
            fragment("?->>'text' <> ''", e.payload)
      )
    )
  end

  @doc """
  Delete the :narration events produced for a given `turn_id`.

  The timeline is append-only by convention, but a beat that hit max_tokens
  leaves a HALF narration on the log (the model streamed some text before being
  cut off) which then sits next to the complete narration the brevity retry
  produces — so the player sees a truncated "…correa de la moch" immediately
  followed by the good line. Wiping the failed-turn narrations before the retry
  keeps the timeline clean. Dice/system/action events for that turn are kept
  (they're real outcomes); only the partial narration is dropped.
  """
  @spec delete_narrations_for_turn(term(), String.t()) :: {non_neg_integer(), term()}
  def delete_narrations_for_turn(game_id, turn_id) do
    Repo.delete_all(
      from(e in GameEvent,
        where:
          e.game_id == ^game_id and e.type == :narration and
            fragment("?->>'turn_id' = ?", e.payload, ^turn_id)
      )
    )
  end
end
