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
        Participant.new(id: p.name, kind: p.kind)
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

    dm_agent =
      DM.new(model,
        story_bible: game.story_bible || %{},
        summarizer: summarizer,
        max_tokens: Dragonex.Models.dm_max_tokens(),
        # Reasoning effort override (nil unless the Ajustes modal set one). Rides
        # in ModelSettings.extra → the provider's reasoning knob.
        reasoning: Dragonex.Models.reasoning_extra(),
        # With shared-history reconstruction from game_events, the history
        # reflects the partida's full timeline (not just the DM's). Cap at
        # 250k tokens — most modern long-context models (1M window) handle
        # 200-300k comfortably, and compacting sooner would discard the
        # hard-won cross-agent context that's the whole point.
        compaction_threshold: env_int("DRAGONEX_COMPACTION_THRESHOLD", 250_000),
        compaction_keep_recent: env_int("DRAGONEX_COMPACTION_KEEP_RECENT", 12)
      )

    {:ok, dm} =
      Server.start_link(
        agent: dm_agent,
        agent_id: "game-#{game_id}-dm",
        pubsub: :local
      )

    # TurnMaster (D25): cheap agent that only picks who acts next. Own model so
    # tests can inject a scripted TM without touching the DM script. When the
    # DM is a %Test{} (offline suite), default TM to Test too — otherwise a
    # live API key in .env.dev would make every test hit the network.
    tm_model =
      Keyword.get(opts, :turnmaster_model) || default_turnmaster_model(model)

    tm_agent = TurnMaster.new(tm_model, max_tokens: 256)

    {:ok, turnmaster} =
      Server.start_link(
        agent: tm_agent,
        agent_id: "game-#{game_id}-turnmaster",
        pubsub: :local
      )

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

    %Dragonex.Game{
      game_id: game_id,
      game: game,
      session: session,
      dm: dm,
      turnmaster: turnmaster,
      pc_agents: pc_agents,
      model: model,
      roller: roller,
      participants: participants,
      intents: game.intents || %{},
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

  # --------------------------------------------------------------- models

  defp default_model, do: Dragonex.Models.dm()

  # Live TM only when the DM itself is a live provider. Offline/flaky/test
  # models (and any custom %ExAgent.Model{} used in tests) get a quiet Test TM
  # that soft-falls back to WorldDriven — otherwise a keyed .env would make
  # every suite hit the network, and FlakyModel would burn retry budget on TM.
  defp default_turnmaster_model(%ExAgent.Models.OpenRouter{}), do: Dragonex.Models.turnmaster()
  defp default_turnmaster_model(%ExAgent.Models.OpenCode{}), do: Dragonex.Models.turnmaster()

  defp default_turnmaster_model(_offline),
    do: %ExAgent.Models.Test{label: "(turnmaster: use WorldDriven)"}

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
