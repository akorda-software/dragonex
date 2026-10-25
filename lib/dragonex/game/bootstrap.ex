defmodule Dragonex.Game.Bootstrap do
  @moduledoc """
  Game bootstrapping: rebuild the in-memory engine (Session + DM/TurnMaster/PC
  agents) from the persisted Postgres row. The Session is the motor
  (WorldDriven); the Game owns durability.

  Extracted from `Dragonex.Game.init/1`. Runs inside the Game GenServer's
  process at start (and on every crash-restart rehydration).
  """

  alias Dragonex.{DM, Games, PCAgent, TurnMaster}
  alias Dragonex.Games.Participant, as: DBParticipant
  alias ExAgent.{Server, Session}
  alias ExAgent.Session.Participant
  alias Dragonex.TurnPolicy.WorldDriven

  def rehydrate(game_id, game, opts) do
    world = Games.load_world(game)

    participants =
      game.participants
      |> Enum.map(fn %DBParticipant{name: name, kind: kind, user_id: uid} ->
        {name, %{name: name, kind: kind, user_id: uid}}
      end)
      |> Map.new()

    session_participants =
      Enum.map(game.participants, fn p ->
        Participant.new(id: p.name, kind: if(p.kind == :ai, do: :agent, else: :human))
      end)

    {:ok, session} =
      Session.start_link(
        shared_state: world,
        policy: {WorldDriven, dm: "dm"},
        participants: session_participants,
        session_id: "game-#{game_id}",
        pubsub: :local
      )

    {:ok, _first} = Session.start(session)

    # Restore the turn position. Session.start() picked the policy's first; jump
    # to the stored current so a resumed partida picks up exactly where it left off.
    restore_turn(session, game.current_participant)

    # The table's own AI (D242) unless the caller injects models (tests,
    # settings restart). Explicit opts always win.
    opts =
      if Keyword.has_key?(opts, :model),
        do: opts,
        else: Keyword.merge(Dragonex.GameAI.models(game), opts)

    model = Keyword.get(opts, :model) || default_model()
    # The dice roller is injected (tests use a fixed one). We no longer wrap it
    # to broadcast per-die `:dice_roll` events: instead each closed roll GROUP
    # broadcasts once via `RollLog.on_close` with the full labeled entry (reason
    # + dice + total + against + outcome), so the modal opens exactly once per
    # roll with everything it needs, never twice.
    roller = Keyword.get(opts, :roller) || (&Dragonex.Dice.roll/1)

    # Modelo-por-rol + caching: the DM bakes the (stable) story bible into its
    # system prefix, and a cheap summarizer powers compaction of old history.
    summarizer = Keyword.get(opts, :summarizer) || Dragonex.Models.summarizer()

    {:ok, dm} = start_dm_agent(game_id, game, model, summarizer)

    # TurnMaster (D25): cheap agent that only picks who acts next. Own model so
    # tests can inject a scripted TM without touching the DM script. When the
    # DM is a %Test{} (offline suite), default TM to Test too — otherwise a
    # live API key in .env.dev would make every test hit the network.
    tm_model =
      Keyword.get(opts, :turnmaster_model) || default_turnmaster_model(model)

    {:ok, turnmaster} = start_turnmaster_agent(game_id, tm_model)

    # Create independent agents for AI-controlled PCs. Each gets its own
    # personality-driven prompt and uses the same combat tools. The DM handles
    # monster turns; AI PCs handle their own turns with their own voice.
    pc_agents =
      participants
      |> Enum.filter(fn {name, %{kind: kind}} -> kind == :ai and name != "dm" end)
      |> Enum.map(fn {name, _} ->
        character = Map.get(world.characters, name)

        if character do
          start_pc_agent(game_id, model, summarizer, name, character, "pc-#{name}")
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    status =
      case game.status do
        s when s in [:running, :waiting] -> :running
        s -> s
      end

    # Fresh partidas open on TurnMaster so it can hand the first beat to the DM.
    # Resumed partidas already have a current_participant — start on :actor so
    # that human resumes into :waiting without an extra TM hop.
    loop_phase = if is_nil(game.current_participant), do: :turnmaster, else: :actor

    # Mini-turn bookkeeping is ephemeral, but its authoritative kind/owner
    # survives in World. Reopening a paused reaction must not mark the
    # reactor's main initiative slot or lose the interrupted owner's floor.
    pending = Map.get(world, :pending_turn) || %{}

    mini? =
      world.phase == :combat and (world.turn_kind == "reaction" or pending["kind"] == "reaction")

    Dragonex.Game.RunLifecycle.watch([self()], [session, dm, turnmaster])

    %Dragonex.Game{
      game_id: game_id,
      game: game,
      session: session,
      dm: dm,
      turnmaster: turnmaster,
      combat_handoffs: Keyword.get(opts, :combat_handoffs, :initiative),
      pc_agents: pc_agents,
      model: model,
      summarizer: summarizer,
      scene_model: Keyword.get(opts, :scene_model) || default_scene_model(model, summarizer),
      roller: roller,
      participants: participants,
      intents: game.intents || %{},
      pending_mini: mini?,
      interrupted: if(mini?, do: world.turn_owner),
      status: status,
      loop_phase: loop_phase
    }
  end

  defp restore_turn(_session, nil), do: :ok

  defp restore_turn(session, current) do
    case Session.handoff(session, current) do
      {:ok, ^current} -> :ok
      {:error, _} -> :ok
    end
  end

  @doc """
  Agent id of the game's TurnMaster server. Also the key for its PubSub topic
  (`ExAgent.Event.agent_topic/1`) — `Beats` subscribes there to capture what a
  failed TM beat actually did (tool name + args) for the failure warning.
  """
  @spec turnmaster_agent_id(term()) :: String.t()
  def turnmaster_agent_id(game_id), do: "game-#{game_id}-turnmaster"

  @doc false
  def start_dm_agent(game_id, game, model, summarizer) do
    agent =
      DM.new(model,
        story_bible: game.story_bible || %{},
        dm_style: game.dm_style,
        summarizer: summarizer,
        max_tokens: Dragonex.Models.dm_max_tokens(),
        reasoning: Dragonex.Models.request_extra(),
        compaction_threshold: env_int("DRAGONEX_COMPACTION_THRESHOLD", 250_000),
        compaction_keep_recent: env_int("DRAGONEX_COMPACTION_KEEP_RECENT", 12)
      )

    Server.start_link(agent: agent, agent_id: "game-#{game_id}-dm", pubsub: :local)
  end

  @doc false
  def start_turnmaster_agent(game_id, model),
    do:
      Server.start_link(
        agent: TurnMaster.new(model),
        agent_id: turnmaster_agent_id(game_id),
        pubsub: :local
      )

  @doc "Replace role agents in the current Game, keeping its Session and turn bookkeeping."
  def replace_agents(state, opts) do
    model = Keyword.get(opts, :model) || default_model()
    summarizer = Keyword.get(opts, :summarizer) || Dragonex.Models.summarizer()
    tm_model = Keyword.get(opts, :turnmaster_model) || default_turnmaster_model(model)
    {:ok, dm} = start_dm_agent(state.game_id, state.game, model, summarizer)
    {:ok, turnmaster} = start_turnmaster_agent(state.game_id, tm_model)
    world = Session.read_state(state.session)

    pcs =
      Map.new(state.pc_agents, fn {name, _pid} ->
        suffix =
          if state.participants[name].kind == :human, do: "auto-#{name}", else: "pc-#{name}"

        start_pc_agent(state.game_id, model, summarizer, name, world.characters[name], suffix)
      end)

    Dragonex.Game.RunLifecycle.watch([self()], [dm, turnmaster])

    %{
      state
      | model: model,
        summarizer: summarizer,
        scene_model: default_scene_model(model, summarizer),
        dm: dm,
        turnmaster: turnmaster,
        pc_agents: pcs
    }
  end

  # --------------------------------------------------------------- models

  defp default_model, do: Dragonex.Models.dm()

  # Live TM only when the DM itself is a live provider. Offline/flaky/test
  # models (and any custom %ExAgent.Model{} used in tests) get a quiet Test TM
  # that soft-falls back to WorldDriven — otherwise a keyed .env would make
  # every suite hit the network, and FlakyModel would burn retry budget on TM.
  defp default_turnmaster_model(model) do
    if Dragonex.Models.live?(model),
      do: Dragonex.Models.turnmaster(),
      else: %ExAgent.Models.Test{label: "(turnmaster: use WorldDriven)"}
  end

  defp default_scene_model(model, summarizer),
    do: if(Dragonex.Models.live?(model), do: summarizer, else: model)

  def start_pc_agent(game_id, model, summarizer, name, character, id_suffix) do
    agent =
      PCAgent.new(model, character,
        max_tokens: 2048,
        summarizer: summarizer,
        compaction_threshold: env_int("DRAGONEX_COMPACTION_THRESHOLD", 250_000),
        compaction_keep_recent: env_int("DRAGONEX_COMPACTION_KEEP_RECENT", 12)
      )

    {:ok, pid} =
      Server.start_link(
        agent: agent,
        agent_id: "game-#{game_id}-#{id_suffix}",
        pubsub: :local
      )

    # This also covers human autoplay agents created after rehydration.
    Dragonex.Game.RunLifecycle.watch([self()], [pid])
    {name, pid}
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      s ->
        case Integer.parse(s) do
          {n, ""} -> n
          _ -> default
        end
    end
  end
end
