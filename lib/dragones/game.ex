defmodule Dragones.Game do
  @moduledoc """
  The process that owns one partida's turn loop — the application layer above the
  `ExAgent.Session` motor.

  The Game is the **single source of durability**: after every beat it persists
  the live `Dragones.World` (jsonb via Codec), the turn position and an appended
  event to Postgres. The `ExAgent.Session` (WorldDriven) runs in-memory as the
  engine; if the Game process dies, a fresh one rehydrates the same `game_id`
  from Postgres and resumes exactly where it left off.

  ## The loop

    * **AI turn** (the DM, or an AI PC) → run the agent beat in a **Task** so the
      GenServer keeps answering queries/pauses. On completion, advance + persist.
    * **Human turn** → the Game idles in `:waiting` (persisted) until the human
      acts via `act/2`; the beat runs in a Task too, then advances + persists.

  One DM agent (`ExAgent.Server`) resolves every beat, proposing as whichever
  participant's turn it is — the engine's `WorldDriven` policy + `controlled_by?`
  guard enforce that the right side acts. The LLM only narrates; tools resolve.

  ## Restart / rehydrate

  On `init`, the Game loads its row from Postgres, decodes the world, rebuilds
  the Session, and `handoff`s to the stored `current_participant`. If that's an
  AI turn, the beat auto-runs (the partida resumes); if human, it waits.
  """

  use GenServer
  require Logger

  alias Dragones.{DM, Games, PCAgent, RollLog}
  alias Dragones.TurnPolicy.WorldDriven
  alias ExAgent.{Server, Session}
  alias ExAgent.Session.{Participant, SharedState}

  @tick :advance

  # How many events the snapshot ships by default for the chat timeline. Older
  # events are paged in on demand by the LiveView. A partida of moderate length
  # produces ~10-30 events per round (turn marker + 1-2 declarations + dice +
  # narration per beat) — 200 covers most sessions without a reload.
  @chat_window 200

  # Transient provider errors (DeepSeek 503 / rate limit / connection drops /
  # timeouts) are retried with exponential backoff before falling back to the
  # soft "X titubea" narration. The provider usually recovers within seconds;
  # burning up to 3 retries (~14s total worst case) is far better UX than the
  # 5-fallback streaks a transitory outage used to produce.
  @max_transient_retries 3
  @default_transient_backoffs [1_000, 3_000, 10_000]

  # If this many consecutive beats fall through to the soft fallback (titubea),
  # the loop PAUSES instead of feeding another round. Without this, a persistent
  # provider outage (or a wedged scene every agent keeps failing on) produces an
  # infinite "X titubea y el turno pasa de largo" stream that floods the
  # timeline and starves the server (the 503-on-pagination symptom). One full
  # round of 4 participants failing is the trigger.
  @max_fallback_streak 4

  defstruct game_id: nil,
            game: nil,
            session: nil,
            dm: nil,
            pc_agents: %{},
            model: nil,
            roller: nil,
            participants: %{},
            # Pending declared intents: %{participant_name => text}. A human can
            # declare an action anytime; the loop consumes it on their turn.
            intents: %{},
            status: :configuring,
            busy: nil,
            # Consecutive beats that ended in the soft fallback. Reset to 0 on
            # any successful beat. Reaching @max_fallback_streak pauses the loop.
            fallback_streak: 0

  # --------------------------------------------------------------- API

  @doc """
  Start a Game process for `game_id`, rehydrating from Postgres. Options:

    * `:model`  — the LLM model for the DM agent (defaults to env/OpenRouter).
    * `:roller` — a `(sides -> value)` dice fn (defaults to `Dragones.Dice.roll`).
  """
  @spec start_link({term(), keyword()}) :: GenServer.on_start()
  def start_link({game_id, opts}),
    do: GenServer.start_link(__MODULE__, {game_id, opts}, name: Dragones.Game.Supervisor.via(game_id))

  # :transient so a crash restarts (rehydrating from DB) but a clean
  # `stop_game/1` (:normal) does not — the partida is paused in Postgres.
  def child_spec({game_id, opts}) do
    %{
      id: {__MODULE__, game_id},
      start: {__MODULE__, :start_link, [{game_id, opts}]},
      restart: :transient
    }
  end

  @doc "Ensure a Game process is running for `game_id` (starts one if absent)."
  @spec ensure_started(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(game_id, opts \\ []) do
    case Dragones.Game.Supervisor.whereis(game_id) do
      nil -> Dragones.Game.Supervisor.start_game(game_id, opts)
      pid -> {:ok, pid}
    end
  end

  @doc "The participant whose turn it is."
  @spec current(GenServer.server()) :: term() | nil
  def current(server), do: GenServer.call(server, :current)

  @doc "The live world (struct)."
  @spec world(GenServer.server()) :: Dragones.World.t()
  def world(server), do: GenServer.call(server, :world)

  @doc "The Game process status (`:running | :waiting | :paused | :ended`)."
  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @doc "A snapshot for rendering: world, current, status, round."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc """
  A human **declares** an action as `participant` — anytime, even off-turn.

  The intent is recorded (so the partida keeps its plan across a restart). If it
  happens to be that participant's turn right now (and nothing is in flight), the
  Game resolves it immediately; otherwise it is queued and the loop resolves it
  when the turn arrives. The DM then *values* it on resolution — a valid action
  resolves through the tools; an impossible/contradictory one is narrated away or
  ignored by the engine's control guard.
  """
  @spec declare(GenServer.server(), term(), String.t()) :: {:ok, :resolving | :queued} | {:error, term()}
  def declare(server, participant, text), do: GenServer.call(server, {:declare, participant, text})

  @doc "Clear a participant's pending intent (e.g. they changed their mind)."
  @spec clear_intent(GenServer.server(), term()) :: :ok
  def clear_intent(server, participant), do: GenServer.call(server, {:clear_intent, participant})

  @doc "Pause the loop (the current state is persisted). AI beats stop auto-running."
  @spec pause(GenServer.server()) :: :ok | {:error, term()}
  def pause(server), do: GenServer.call(server, :pause)

  @doc "Resume a paused partida; if it's an AI turn, the beat auto-runs."
  @spec resume(GenServer.server()) :: :ok | {:error, term()}
  def resume(server), do: GenServer.call(server, :resume)

  @doc "Enable AI auto-play for a human participant (creates a PCAgent for them)."
  @spec enable_auto_play(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def enable_auto_play(server, participant),
    do: GenServer.call(server, {:set_auto_play, participant, true})

  @doc "Disable AI auto-play for a participant (returns them to manual control)."
  @spec disable_auto_play(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def disable_auto_play(server, participant),
    do: GenServer.call(server, {:set_auto_play, participant, false})

  @doc """
  Test/debug helper: block until `predicate.(snapshot)` is truthy (or times out).
  `snapshot/1` returns `%{world, current, status, round}`. Safer than
  `await_turn/3` for AI participants, which the loop auto-advances past quickly.
  """
  @spec await(GenServer.server(), (map() -> boolean()), non_neg_integer()) :: :ok | :timeout
  def await(server, predicate, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if predicate.(snapshot(server)), do: :done, else: :wait
    end)
    |> Enum.find_value(fn
      :done -> :ok
      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: :timeout,
          else: (Process.sleep(10); nil)
    end)
  end

  @doc """
  Test/debug helper: block until `Session.current` equals `participant` (or
  times out). Lets a test follow an async AI beat to its completion.
  """
  @spec await_turn(GenServer.server(), term(), non_neg_integer()) :: :ok | :timeout
  def await_turn(server, participant, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if current(server) == participant, do: :done, else: :wait
    end)
    |> Enum.find_value(fn
      :done -> :ok
      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: :timeout,
          else: (Process.sleep(10); nil)
    end)
  end

  # --------------------------------------------------------------- init

  @impl true
  def init({game_id, opts}) do
    case Games.get_game(game_id) do
      nil ->
        {:stop, {:not_found, game_id}}

      %Games.Game{} = game ->
        state = rehydrate(game_id, game, opts)
        send(self(), @tick)
        {:ok, state}
    end
  end

  # Rebuild the in-memory engine from the persisted row. The Session is the
  # motor (WorldDriven); the Game owns durability via Postgres.
  defp rehydrate(game_id, game, opts) do
    world = Games.load_world(game)

    participants =
      game.participants
      |> Enum.map(fn %Games.Participant{name: name, kind: kind, user_id: uid} ->
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
    roller = Keyword.get(opts, :roller) || &Dragones.Dice.roll/1

    # Modelo-por-rol + caching: the DM bakes the (stable) story bible into its
    # system prefix, and a cheap summarizer powers compaction of old history.
    summarizer = Keyword.get(opts, :summarizer) || Dragones.Models.summarizer()

      dm_agent =
        DM.new(model,
          story_bible: game.story_bible || %{},
          summarizer: summarizer,
          max_tokens: Dragones.Models.dm_max_tokens(),
          # With shared-history reconstruction from game_events, the history
          # reflects the partida's full timeline (not just the DM's). Cap at
          # 250k tokens — most modern long-context models (1M window) handle
          # 200-300k comfortably, and compacting sooner would discard the
          # hard-won cross-agent context that's the whole point.
          compaction_threshold: env_int("DRAGONES_COMPACTION_THRESHOLD", 250_000),
          compaction_keep_recent: env_int("DRAGONES_COMPACTION_KEEP_RECENT", 12)
        )

    {:ok, dm} =
      Server.start_link(
        agent: dm_agent,
        agent_id: "game-#{game_id}-dm",
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
          agent =
            PCAgent.new(model, character,
              max_tokens: 2048,
              summarizer: summarizer,
              compaction_threshold: env_int("DRAGONES_COMPACTION_THRESHOLD", 250_000),
              compaction_keep_recent: env_int("DRAGONES_COMPACTION_KEEP_RECENT", 12)
            )

          {:ok, pid} =
            Server.start_link(
              agent: agent,
              agent_id: "game-#{game_id}-pc-#{name}",
              pubsub: :local
            )

          {name, pid}
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    status =
      case game.status do
        s when s in [:running, :waiting] -> :running
        s -> s
      end

    %__MODULE__{
      game_id: game_id,
      game: game,
      session: session,
      dm: dm,
      pc_agents: pc_agents,
      model: model,
      roller: roller,
      participants: participants,
      intents: game.intents || %{},
      status: status
    }
  end

  defp restore_turn(_session, nil), do: :ok

  defp restore_turn(session, current) do
    case Session.handoff(session, current) do
      {:ok, ^current} -> :ok
      {:error, _} -> :ok
    end
  end
  # --------------------------------------------------------------- calls

  @impl true
  def handle_call(:current, _from, state),
    do: {:reply, Session.current(state.session), state}

  def handle_call(:world, _from, state),
    do: {:reply, Session.read_state(state.session), state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:snapshot, _from, state) do
    world = Session.read_state(state.session)

    snap = %{
      game_id: state.game_id,
      world: world,
      current: Session.current(state.session),
      status: state.status,
      round: world.round,
      # The roster {name => kind} so a viewer can claim a human participant.
      participants: state.participants,
      # Pending declared intents {name => text} — the UI shows each viewer's plan.
      intents: state.intents,
      # Human participants currently auto-played by an agent (so the toggle
      # reflects real engine state across reloads / multiple tabs).
      auto: auto_humans(state),
      # The chat timeline: recent visible events, oldest-first. Bundled here so
      # the LiveView renders purely from the snapshot (no direct Repo access).
      # Capped at @chat_window; the LiveView paginates older events on demand
      # via Games.events_before/3 when the user scrolls to the top.
      events: Games.recent_events(state.game_id, @chat_window),
      # Whether older events exist beyond the loaded window — drives the
      # "cargar más" button at the top of the log.
      has_more_events: Games.count_events(state.game_id) > @chat_window
    }

    {:reply, snap, state}
  end

  def handle_call({:declare, participant, text}, _from, state) do
    text = String.trim(text)
    current = Session.current(state.session)

    cond do
      # Only a human participant can declare (not the DM / monsters).
      not human?(state, participant) ->
        {:reply, {:error, :not_your_turn}, state}

      text == "" ->
        # Empty declare clears any prior intent.
        intents = Map.delete(state.intents, participant)
        Games.save_intents(state.game_id, intents)
        {:reply, {:ok, :queued}, %{state | intents: intents}}

      true ->
        # Record the intent (durable) so it survives a restart / off-turn wait.
        intents = Map.put(state.intents, participant, text)
        Games.save_intents(state.game_id, intents)
        state = %{state | intents: intents}

        # Resolve immediately if it's this participant's turn and idle.
        can_resolve_now? =
          state.status == :waiting and state.busy == nil and current == participant

        if can_resolve_now? do
          # Live resolution: append the :turn marker first so the consumed
          # intent and the ensuing beat share the same turn_id (matches the
          # loop path through advance/1).
          turn_id = generate_turn_id()
          world = Session.read_state(state.session)
          append_turn_marker(state.game_id, participant, turn_id, world)
          state = consume_intent(state, participant, turn_id, world)
          broadcast_updated(state)
          {:reply, {:ok, :resolving}, state}
        else
          broadcast_updated(state)
          {:reply, {:ok, :queued}, state}
        end
    end
  end

  def handle_call({:clear_intent, participant}, _from, state) do
    intents = Map.delete(state.intents, participant)
    Games.save_intents(state.game_id, intents)
    broadcast_updated(%{state | intents: intents})
    {:reply, :ok, %{state | intents: intents}}
  end

  def handle_call(:pause, _from, %{status: status} = state) when status in [:running, :waiting] do
    {:ok, _} = Games.set_status(state.game_id, :paused)
    broadcast_updated(state)
    {:reply, :ok, %{state | status: :paused}}
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, {:not_running, state.status}}, state}

  def handle_call(:resume, _from, %{status: :paused} = state) do
    {:ok, _} = Games.set_status(state.game_id, :running)
    state = %{state | status: :running}
    broadcast_updated(state)
    send(self(), @tick)
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state),
    do: {:reply, {:error, {:not_paused, state.status}}, state}

  def handle_call({:set_auto_play, participant, true}, _from, state) do
    cond do
      # Already has an agent (original AI or already auto-playing)
      Map.has_key?(state.pc_agents, participant) ->
        {:reply, :ok, state}

      # Human participant → create an agent for them
      human?(state, participant) ->
        character = world_character(state, participant)

        if character do
          agent =
            PCAgent.new(state.model, character,
              max_tokens: 2048,
              summarizer: Dragones.Models.summarizer(),
              compaction_threshold: env_int("DRAGONES_COMPACTION_THRESHOLD", 250_000),
              compaction_keep_recent: env_int("DRAGONES_COMPACTION_KEEP_RECENT", 12)
            )

          {:ok, pid} =
            Server.start_link(
              agent: agent,
              agent_id: "game-#{state.game_id}-auto-#{participant}",
              pubsub: :local
            )

          state = %{state | pc_agents: Map.put(state.pc_agents, participant, pid)}

          # If we're auto-enabling on the human's OWN waiting turn, the loop is
          # parked in :waiting and advance() no-ops on non-:running status — the
          # tick would do nothing and the game wedges. Flip to :running so the
          # PCAgent actually plays this turn (mirrors consume_intent).
          state =
            if state.status == :waiting and Session.current(state.session) == participant do
              %{state | status: :running}
            else
              state
            end

          send(self(), @tick)
          broadcast_updated(state)
          {:reply, :ok, state}
        else
          {:reply, {:error, :not_found}, state}
        end

      true ->
        {:reply, {:error, :not_human}, state}
    end
  end

  def handle_call({:set_auto_play, participant, false}, _from, state) do
    # Only remove agents for human participants (auto-play agents).
    # Original AI PC agents are kept (they were created in rehydrate).
    if human?(state, participant) do
      case Map.get(state.pc_agents, participant) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        _ -> :ok
      end

      state = %{state | pc_agents: Map.delete(state.pc_agents, participant)}
      broadcast_updated(state)
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  # --------------------------------------------------------------- loop

  @impl true
  def handle_info(@tick, state) do
    {:noreply, advance(state)}
  rescue
    # A deleted game (its row removed while the GenServer kept running) surfaces
    # as a foreign_key_constraint violation when we try to append events. Without
    # this guard the process crashes on every tick and the :transient supervisor
    # restarts it in an infinite loop, flooding the log. Stop cleanly instead —
    # the partida is gone, there is nothing more to do.
    e in Ecto.ConstraintError ->
      Logger.warning(
        "dragones game #{state.game_id} stopping: its row is gone (#{Exception.message(e)})"
      )

      {:stop, :normal, state}
  end

  # A beat Task finished successfully. Guarded on `is_reference/1` so the
  # clause only matches real Task monitor refs — otherwise it would shadow the
  # `{:retry_beat, turn_id}` tuple below (a 2-tuple carrying an atom, not a ref).
  def handle_info({ref, result}, %{busy: busy} = state) when is_reference(ref) do
    cond do
      is_map(busy) and busy.ref == ref ->
        Process.demonitor(ref, [:flush])
        {:noreply, handle_beat_result(state, result)}

      true ->
        # Stale result from a beat no longer tracked (e.g. after a restart) — drop it.
        {:noreply, state}
    end
  end

  # A beat Task crashed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("dragones game #{state.game_id} beat crashed: #{inspect(reason)}")
    {:noreply, handle_beat_result(state, {:error, {:crashed, reason}})}
  end

  # The backoff window for a transient-provider retry elapsed — relaunch the
  # beat. While we were sleeping, `busy` was kept as a `pending_retry` marker
  # (no Task ref) so `advance/1` did NOT kick a competing beat and the turn
  # position stayed put. If the user paused during the window, re-arm the timer
  # and wait for resume rather than firing a beat under a paused loop.
  def handle_info({:retry_beat, turn_id}, %{busy: %{turn_id: turn_id, pending_retry: true}} = state) do
    if state.status != :running do
      Process.send_after(self(), {:retry_beat, turn_id}, 500)
      {:noreply, state}
    else
      %{
        participant: participant,
        instruction: instruction,
        transient_retries: tr,
        max_token_retries: mr
      } = state.busy

      world = Session.read_state(state.session)
      retries = %{transient_retries: tr, max_token_retries: mr}
      state = run_beat(%{state | busy: nil, status: :running}, participant, instruction, turn_id, world, retries)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The one-step advance: look at whose turn it is and either kick an AI beat or
  # settle into :waiting for a human. Never auto-chains more than one beat per
  # tick (each completed beat schedules the next).
  defp advance(%{status: status} = state) when status != :running, do: state

  defp advance(%{busy: b} = state) when b != nil, do: state

  defp advance(state) do
    case Session.current(state.session) do
      nil ->
        persist(state, :ended)
        %{state | status: :ended}

      current ->
        # Defer the :turn marker until we KNOW we're going to act. A human who's
        # waiting for input doesn't get a marker yet — it lands when they
        # declare (their path) or when their queued intent is consumed (loop
        # path), so we never emit two markers for one turn.
        world = Session.read_state(state.session)

        cond do
          # Has an AI agent (original AI PC or auto-play enabled human)
          ai_pc?(state, current) ->
            turn_id = generate_turn_id()
            append_turn_marker(state.game_id, current, turn_id, world)

            character = world_character(state, current)
            base = PCAgent.instruction(current, character || Dragones.Character.new(name: current), world)
            # Prompts alone couldn't stop a bot from re-declaring the same
            # non-action ("¿subimos al círculo?" x N) every turn. This compares
            # its last two narrations and, when they're near-duplicates, stitches
            # a hard anti-loop nudge onto the instruction forcing a DIFFERENT
            # concrete action this turn.
            instruction = with_pc_anti_loop(state.game_id, current, base)
            state = run_beat(state, current, instruction, turn_id, world)
            %{state | status: :running}

          human?(state, current) ->
            case Map.get(state.intents, current) do
              text when is_binary(text) and text != "" ->
                turn_id = generate_turn_id()
                append_turn_marker(state.game_id, current, turn_id, world)
                state = %{state | status: :running}
                consume_intent(state, current, turn_id, world)

              _ ->
                persist(state, :waiting)
                broadcast_updated(state)
                %{state | status: :waiting}
            end

          true ->
            # DM's turn (monsters/NPCs).
            turn_id = generate_turn_id()
            append_turn_marker(state.game_id, current, turn_id, world)

            # Detect stalls where the partida loops without progress:
            #   * post-combate limbo — combate ended but the timeline hasn't
            #     moved past it (PCs re-declare "¿seguimos?" forever).
            #   * exploration limbo — long stretches of pure narration with no
            #     ability check, no spawn, no scene change (the "¿empezamos con
            #     el círculo?" x 10 turns pattern). The DM gets a special
            #     instruction forcing an avance instead of "¿qué hacéis?".
            instruction =
              cond do
                post_combat_limbo?(state.game_id) ->
                  dm_post_combat_instruction()

                exploration_limbo?(state.game_id, world) ->
                  Logger.info("dragones game #{state.game_id} exploration limbo — forcing DM avance")
                  dm_advance_instruction()

                true ->
                  dm_instruction()
              end

            # Bug #4: the DM occasionally narrates a PC acting ("*Lyra ataca al
            # goblin*"). Rule 14 forbids it but prompts alone leak through, so
            # when the DM's LAST narration matches "<pc> <action verb>", this
            # turn's instruction gets a rule-14 reminder stitched on top.
            instruction = with_dm_no_puppet_nudge(state.game_id, world, instruction)
            # Anti-repeat: keep DM narration varied (no "se desvanece en humo
            # sulfúrico" x N). Applied after the puppet nudge so both can stack.
            instruction = with_dm_anti_repeat(state.game_id, instruction)
            # Ghost combat v2: if the DM narrated a hostile appearing without
            # spawning it, force a spawn_monster this turn.
            instruction = with_dm_unspawned_hostile_nudge(state.game_id, world, instruction)
            # Language guard: DeepSeek sometimes drifts into English mid-scene.
            # If the DM's last narration reads English, force Spanish this turn.
            instruction = with_dm_spanish_nudge(state.game_id, instruction)

            state = run_beat(state, current, instruction, turn_id, world)
            %{state | status: :running}
        end
    end
  end

  defp generate_turn_id do
    # 8 random hex chars — enough to be unique per turn within a partida, short
    # enough to read in a debug log.
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp append_turn_marker(game_id, actor, turn_id, world) do
    {:ok, _} =
      Games.append_event(game_id, :turn, actor, "all", %{
        turn_id: turn_id,
        round: world.round,
        phase: world.phase,
        kind: :start
      })
  end

  # Consume a participant's pending intent: log the action, run the beat, clear
  # the intent (durable). Used both by `declare` (live) and the loop (queued).
  defp consume_intent(state, participant, turn_id, world) do
    text = Map.get(state.intents, participant, "")
    intents = Map.delete(state.intents, participant)
    state = %{state | intents: intents}

    {:ok, _} =
      Games.append_event(state.game_id, :action, participant, "all", %{
        text: text,
        turn_id: turn_id,
        round: world.round,
        phase: world.phase
      })

    Games.save_intents(state.game_id, intents)

    state = run_beat(state, participant, human_instruction(participant, text), turn_id, world)
    %{state | status: :running}
  end

  defp handle_beat_result(state, result) do
    current = state.busy.participant
    # The phase the beat STARTED in. A beat that began in exploration may flip
    # into combat (the DM rolled initiative) — that's the combat-START beat, not
    # a wrap, so round advancement must ignore it.
    beat_phase = Map.get(state.busy, :phase)
    beat_instruction = Map.get(state.busy, :instruction)
    beat_turn_id = Map.get(state.busy, :turn_id)
    # Separate retry budgets: a max_tokens retry and a transient-provider retry
    # are independent failure modes, so each gets its own counter. Keeping them
    # apart means a beat that fails max_tokens, then on retry hits a 503, can
    # still exhaust its transient budget (and vice-versa).
    beat_max_token_retries = Map.get(state.busy, :max_token_retries, 0)
    beat_transient_retries = Map.get(state.busy, :transient_retries, 0)
    # Living enemy names when the beat STARTED. Compared against the post-beat
    # world to detect "ghost combat": the DM spawned/narrated a hostile entering
    # the scene but never called roll_initiative, leaving the loop stuck in
    # exploration while everyone roleplays a fight that isn't sequenced.
    beat_enemies_before = Map.get(state.busy, :enemies_before, MapSet.new())
    state = %{state | busy: nil}

    case result do
      {:ok, _narration, rolls, usage} ->
        {:ok, _} = Session.end_turn(state.session, current)

        # Dice were already persisted + broadcast LIVE by the RollLog on_close
        # callback as each roll resolved — one modal-open per group, with the
        # full labeled entry (reason + dice + total + against + outcome) in a
        # single shot, never the bare-number-then-context two-step we used to
        # have. Nothing else to do here for dice.
        _ = rolls

        # Narration was already persisted by the Dragones.Events capability
        # (after_model_request) the instant the model produced its final text.

        # Log the prompt-caching win (cached vs total input tokens) so the cost
        # saving is visible. Best-effort: a missing usage map just logs nothing.
        log_token_usage(state.game_id, usage)

        # Ghost-combat recovery: if this beat introduced a living enemy while we
        # are still in exploration (the DM spawned a monster — or a hostile
        # appeared — but didn't roll initiative), force combat now so the loop
        # actually sequences the fight. Runs before maybe_end_combat (a no-op in
        # exploration) so the phase flip + initiative land cleanly.
        state = maybe_force_combat(state, beat_enemies_before)

        # Engine-driven combat bookkeeping the DM used to have to remember (and
        # often forgot, leaving combat wedged or the round counter stuck):
        state = maybe_end_combat(state)
        maybe_advance_round(state, current, beat_phase)

        # Honour a pause the user requested while this beat was in flight.
        # Without this, pressing "Pausa" during a bot's beat would be silently
        # undone the moment the beat finished (persist+tick overwrote :paused
        # back to :running). Real pausa means "stop the loop after this beat
        # settles", so we persist as :paused, skip the next tick, and let the
        # user resume explicitly.
        next_status = if state.status == :paused, do: :paused, else: :running

        # A successful beat breaks any fallback streak.
        state = %{state | fallback_streak: 0}

        persist(state, next_status)
        broadcast_updated(state)
        if next_status == :running, do: send(self(), @tick)
        %{state | status: next_status}

      {:error, reason} ->
        cond do
          is_max_tokens(reason) and beat_max_token_retries < 1 ->
            # The model burned through max_tokens mid-output. With shared history
            # the agents have a lot of context to weave into prose, so the FIRST
            # response can run long. Instead of giving up (and rendering "X
            # empieza a decir algo…"), retry ONCE with an explicit "be brief"
            # preamble stitched into the instruction — usually enough for the
            # model to land a tight, complete beat. A second failure still falls
            # through to the soft fallback below.
            Logger.info(
              "dragones game #{state.game_id} beat hit max_tokens for #{current}; retrying with brevity nudge"
            )

            # The beat streamed a partial narration before being cut off (the
            # Events capability persists text the instant the model emits it).
            # Drop that truncated line now so the retry's complete narration
            # doesn't land next to a "…correa de la moch" stub.
            Games.delete_narrations_for_turn(state.game_id, beat_turn_id)

            world = Session.read_state(state.session)
            brief = brief_retry_instruction(beat_instruction, current)
            retries = %{max_token_retries: beat_max_token_retries + 1, transient_retries: 0}
            run_beat(%{state | status: :running}, current, brief, beat_turn_id, world, retries)

          transient_provider_error?(reason) and beat_transient_retries < @max_transient_retries ->
            # Provider hiccup (5xx / 429 / timeout / connection drop / overload).
            # These resolve themselves within seconds, so retry with exponential
            # backoff instead of rendering "X titubea" — which, during a real
            # DeepSeek outage, used to chain 5+ fallbacks in a row.
            schedule_transient_retry(
              state,
              current,
              beat_phase,
              beat_instruction,
              beat_turn_id,
              beat_transient_retries,
              beat_max_token_retries,
              reason
            )

          true ->
            handle_non_max_token_error(state, current, beat_phase, beat_turn_id, reason)
        end
    end
  end

  defp handle_non_max_token_error(state, current, beat_phase, beat_turn_id, reason) do
    Logger.warning("dragones game #{state.game_id} beat failed: #{inspect(reason)}")

    streak = state.fallback_streak + 1
    state = %{state | fallback_streak: streak}

    # The failure note is persisted and later replayed in the shared history.
    # `inspect(reason)` of a Jason.EncodeError carries the offending raw binary
    # (invalid UTF-8 bytes included), which would then wedge every future beat
    # when the history is re-serialized. Truncate to a short, sanitized digest.
    failure_note =
      ("el turno falló: " <> inspect(reason))
      |> String.slice(0, 300)
      |> Dragones.Text.sanitize_utf8()

    {:ok, _} =
      Games.append_event(state.game_id, :system, "system", "dm", %{
        note: failure_note
      })

    # The Events capability persists narration mid-beat (after_model_request) as
    # soon as the model produces text. If the beat then fails (e.g. the model
    # emitted text but no valid final response / tool call after), the narration
    # is ALREADY on the timeline — appending "X titubea y el turno pasa de largo"
    # on top of it reads as a contradiction. So only render the soft fallback
    # when the beat produced NO narration at all.
    already_narrated =
      state.game_id
      |> Games.recent_events(10)
      |> Enum.any?(fn e ->
        e.type == :narration and e.payload["turn_id"] == beat_turn_id
      end)

    unless already_narrated do
      fallback = fallback_narration(current, reason)
      {:ok, _} = Games.append_event(state.game_id, :narration, current, "all", %{text: fallback})
    end

    {:ok, _} = Session.end_turn(state.session, current)

    state = maybe_end_combat(state)
    maybe_advance_round(state, current, beat_phase)

    # Circuit breaker: if beats keep failing, STOP instead of feeding another
    # round. A persistent provider outage (or a wedged scene every agent keeps
    # failing on) would otherwise produce an infinite "X titubea" stream that
    # floods the timeline and starves the server. One pause + a system note lets
    # the user resume manually once the underlying issue clears.
    if streak >= @max_fallback_streak do
      Logger.warning(
        "dragones game #{state.game_id} pausing after #{streak} consecutive fallback beats"
      )

      {:ok, _} =
        Games.append_event(state.game_id, :system, "system", "all", %{
          note:
            "⏸ La partida se ha pausado automáticamente tras #{@max_fallback_streak} turnos fallidos seguidos. " <>
              "Reanuda manualmente cuando quieras continuar."
        })

      persist(state, :paused)
      broadcast_updated(state)
      # No tick — the loop stops here until the user resumes.
      %{state | status: :paused, fallback_streak: 0}
    else
      next_status = if state.status == :paused, do: :paused, else: :running

      persist(state, next_status)
      broadcast_updated(state)
      if next_status == :running, do: send(self(), @tick)
      %{state | status: next_status}
    end
  end

  # Brevity nudge for a max_tokens retry. Prepends a hard "keep it tight"
  # instruction to whatever the original beat instruction was, so the model
  # lands a complete response inside max_tokens on the second shot.
  defp brief_retry_instruction(original, actor) do
    brief =
      "⏱ INTENTA ANTERIORMENTE: tu respuesta se cortó a mitad por el límite de tokens. " <>
        "ESTA VEZ SÉ EXTREMADAMENTE BREVE: 1-2 frases de narración como mucho, " <>
        "una sola llamada a herramienta si la necesitas, y reacciona en una frase corta. " <>
        "NADA de párrafos largos, listas, ni descripciones elaboradas. Conciso y al grano.\n\n"

    brief <> (original || "Es el turno de #{actor}. Actúa en personaje.")
  end

  # True when the beat failed because the model hit max_tokens (either bare
  # atom or the {:max_tokens_exceeded, model_name} tuple shape).
  defp is_max_tokens(:max_tokens_exceeded), do: true
  defp is_max_tokens({:max_tokens_exceeded, _}), do: true
  defp is_max_tokens(_), do: false

  # True when the beat failed because of a transient provider fault — one that
  # retrying is likely to fix. DeepSeek/OpenRouter surface these as
  # `{:model_request_failed, %ExAgent.RequestError{}}`. We treat as transient:
  #   * HTTP 5xx and 429 (overloaded / rate-limited / gateway blip)
  #   * transport-level :timeout and :request_failed (connection drops)
  #   * :provider_error bodies that read as overload/rate/unavailable
  # Non-transient (4xx other than 429, missing_credentials, malformed request)
  # fall straight through to the soft fallback — retrying those just wastes time.
  defp transient_provider_error?({:model_request_failed, %ExAgent.RequestError{} = err}) do
    case err.reason do
      :timeout -> true
      :request_failed -> true
      :http_error -> err.status == 429 or (is_integer(err.status) and err.status >= 500)
      :provider_error -> transient_body?(err.body)
      _ -> false
    end
  end

  # A crashed Task is not a provider fault; don't retry it.
  defp transient_provider_error?({:crashed, _}), do: false
  defp transient_provider_error?(_), do: false

  defp transient_body?(body) when is_binary(body) do
    down = String.downcase(body)

    String.contains?(down, "rate") or String.contains?(down, "overload") or
      String.contains?(down, "capacity") or String.contains?(down, "temporarily") or
      String.contains?(down, "try again") or String.contains?(down, "timeout") or
      String.contains?(down, "unavailable") or String.contains?(down, "503") or
      String.contains?(down, "529") or String.contains?(down, "internal error")
  end

  defp transient_body?(body) when is_map(body), do: transient_body?(inspect(body))
  defp transient_body?(_), do: false

  # Backoff slot for the Nth transient retry (0-indexed): 1s, 3s, 10s, then cap.
  # Overridable via `{:dragones, :transient_backoffs}` app env so tests can shrink
  # the windows to milliseconds instead of sleeping through real seconds.
  defp transient_backoff(attempt) when attempt >= 0 do
    backoffs = Application.get_env(:dragones, :transient_backoffs, @default_transient_backoffs)
    Enum.at(backoffs, attempt, List.last(backoffs))
  end

  # Park the beat as `pending_retry` and arm a timer. While sleeping, `busy` is
  # non-nil (so `advance/1` won't fire a competing beat) but carries no Task ref
  # (so stale `{ref, _}` / `:DOWN` messages can't match it). The retry lands in
  # `handle_info({:retry_beat, turn_id})`.
  defp schedule_transient_retry(
         state,
         current,
         beat_phase,
         instruction,
         turn_id,
         transient_retries,
         max_token_retries,
         reason
       ) do
    backoff = transient_backoff(transient_retries)

    Logger.warning(
      "dragones game #{state.game_id} transient provider error for #{current} " <>
        "(#{inspect(reason)}); retry #{transient_retries + 1}/#{@max_transient_retries} in #{backoff}ms"
    )

    Process.send_after(self(), {:retry_beat, turn_id}, backoff)

    # Keep status as :running (a retry is mid-flight), but do NOT persist/tick —
    # the world hasn't changed and we don't want advance() to fire. busy stays
    # populated so the loop stays parked until the retry resolves.
    %{
      state
      | status: :running,
        busy: %{
          pending_retry: true,
          participant: current,
          phase: beat_phase,
          turn_id: turn_id,
          instruction: instruction,
          transient_retries: transient_retries + 1,
          max_token_retries: max_token_retries
        }
    }
  end

  # One line of in-fiction prose for a beat that failed at the engine level.
  # Keeps the partida flowing instead of pausing on bot/DM hiccups. The actual
  # cause is logged + appended as a dm-only :system event for debugging.
  defp fallback_narration(actor, reason) do
    cond do
      reason == :max_tokens_exceeded or match?({:max_tokens_exceeded, _}, reason) ->
        if actor == "dm" do
          "La escena se queda a medias; el narrador recupera el hilo un instante después."
        else
          "#{actor} empieza a decir algo, pero se queda pensando y no concluye su acción."
        end

      match?({:unexpected_model_behavior, _}, reason) ->
        if actor == "dm" do
          "El mundo contiene la respiración un momento, a la espera del siguiente movimiento."
        else
          "#{actor} duda, sin terminar de decidir qué hacer este turno."
        end

      true ->
        if actor == "dm" do
          "Una pausa breve se instala en la mesa antes de que la escena continúe."
        else
          "#{actor} titubea y el turno pasa de largo."
        end
    end
  end

  defp log_token_usage(game_id, %{input_tokens: input} = usage) when is_integer(input) do
    cached = Dragones.Models.cached_tokens(usage)

    if cached > 0 do
      ratio = Float.round(cached / max(input, 1) * 100, 1)
      Logger.info("dragones game #{game_id} tokens: #{input} in (#{cached} cached, #{ratio}%)")
    end
  end

  defp log_token_usage(_game_id, _usage), do: :ok

  # --------------------------------------------------------------- beats

  # Launch one beat as `participant` in a supervised Task. The GenServer stays
  # responsive; the result arrives via handle_info({ref, result}).
  #
  # The beat context (`turn_id`, `round`, `phase`) is threaded through `deps`
  # so the `Dragones.Events` capability can attach it to every event it
  # publishes mid-beat, and the `RollLog.on_close` callback can do the same
  # for each roll the moment it lands. Both publish live via PubSub — the chat
  # fills in as the beat unfolds, not collapsed at the end.
  defp run_beat(
         %{session: session, roller: roller, game_id: game_id} = state,
         participant,
         instruction,
         turn_id,
         world,
         retries \\ %{max_token_retries: 0, transient_retries: 0}
       ) do
    # `retries` is threaded in from handle_beat_result so a retried beat keeps
    # its retry budget honest — a max_tokens retry that then fails with a 503
    # still gets its full transient-retry budget, and a transient retry that
    # then runs long still gets one max_tokens nudge. First attempts pass the
    # default zeroed map.

    agent = agent_for(state, participant)
    # name -> :ai | :human, so the DM knows who auto-acts and who waits for input.
    kinds = state.participants |> Map.new(fn {n, p} -> {n, p.kind} end)
    prompt = DM.turn_prompt(world, participant, instruction, "dm", kinds)
    shared = SharedState.new(session, participant)

    beat = %{
      game_id: game_id,
      turn_id: turn_id,
      actor: participant,
      round: world.round,
      phase: world.phase
    }

    # Each finalized roll → persisted as a :dice event (with turn_id) + PubSub
    # broadcast. Captured here (in the Game's process) so the closure carries
    # `beat`, then invoked from inside the beat Task via the recorder.
    on_roll_closed = fn entry ->
      payload = Map.merge(entry, %{turn_id: turn_id, round: world.round, phase: world.phase})
      {:ok, _} = Games.append_event(game_id, :dice, participant, "all", payload)
      broadcast_roll_group(game_id, entry)
      broadcast_updated(game_id)
    end

    # Token-level streaming of narration: each text delta the model emits is
    # broadcast immediately so the chat renders it word-by-word as it's
    # generated, not collapsed at beat end. The `Events` capability still
    # persists the FINAL text as a :narration event when the response
    # completes — the stream is purely a UI live-preview.
    on_text_delta = fn chunk ->
      try do
        Phoenix.PubSub.broadcast(Dragones.PubSub, topic(game_id), {:text_delta, game_id, turn_id, participant, chunk})
      catch
        _, _ -> :ok
      end
    end

    # Reconstruct the SHARED conversation history from the partida's timeline
    # so every agent (DM + each AI PC) reads what everyone else did — not just
    # its own turns. This is the single source of cross-agent coherence: Vex
    # sees what Lyra narrated, the DM reads Vex's declared intent verbatim,
    # and the rolling dice outcomes are visible to all. Threading this through
    # as :message_history OVERRIDES the Server's per-agent accumulation, so
    # the Server becomes a stateless runner with the Game owning context.
    shared_history =
      game_id
      |> Games.list_events()
      |> Dragones.History.from_events()

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        # Token-level streaming is great UX with a real LLM but the in-process
        # Test model can't propagate its mutated script index through a stream,
        # which would hang the loop. Stream only for real providers.
        stream? = stream_text_for(state.model)

        # One recorder per beat (linked to this Task, so it can never outlive it).
        # It is addressed by pid, so it crosses the process boundary between this
        # beat Task and ExAgent's run Task / parallel tool tasks unscathed.
        {:ok, recorder} = RollLog.start(on_close: on_roll_closed)
        roll_log = %RollLog{base: roller, recorder: recorder}
        deps = %{state: shared, roller: roller, roll_log: roll_log, beat: beat, on_text_delta: on_text_delta}

        result =
          case Server.chat(agent, prompt,
                 deps: deps,
                 stream_text: stream?,
                 message_history: shared_history
               ) do
            {:ok, %{output: narration, usage: usage}} ->
              {:ok, narration, RollLog.entries(recorder), usage}

            {:error, reason} ->
              {:error, reason}
          end

        RollLog.stop(recorder)
        result
      end)

    %{state | busy: %{ref: task.ref, participant: participant, phase: world.phase, turn_id: turn_id, instruction: instruction, max_token_retries: retries.max_token_retries, transient_retries: retries.transient_retries, enemies_before: living_enemies(world)}}
  end

  # Select the right agent for a turn: AI PCs have their own agent; everything
  # else (DM beats, monster turns) goes to the DM agent.
  defp agent_for(%{dm: dm, pc_agents: pc_agents}, name) do
    Map.get(pc_agents, name, dm)
  end

  defp human?(%{participants: ps}, name) do
    case Map.get(ps, name) do
      %{kind: :human} -> true
      _ -> false
    end
  end

  # An AI-controlled participant: either an original AI PC or a human with
  # auto-play enabled (has an entry in pc_agents).
  defp ai_pc?(%{pc_agents: agents}, name) do
    name != "dm" and Map.has_key?(agents, name)
  end

  # The subset of pc_agents that are auto-played HUMANS (not original AI PCs).
  # This is what the LiveView toggle reflects, so it survives reloads and stays
  # consistent across viewers.
  defp auto_humans(%{pc_agents: agents} = state) do
    agents
    |> Map.keys()
    |> Enum.filter(&human?(state, &1))
    |> MapSet.new()
  end

  defp world_character(%{session: session}, name) do
    world = Session.read_state(session)
    Map.get(world.characters, name)
  end

  defp human_instruction(name, text),
    do:
      "Es el turno de #{name}. Estás proponiendo COMO #{name}: en CADA llamada a una herramienta " <>
        "el atacante/conjurador/quien DEBE ser \"#{name}\" (nunca un monstruo — que un monstruo actúe " <>
        "ahora es RECHAZADO). #{name} (un personaje jugador) declara: \"#{if text == "", do: "(pasa)", else: text}\". " <>
        "Resuélvelo por las reglas (llama a la herramienta adecuada con \"#{name}\" como actor) y luego narra. Responde en castellano."

  defp dm_instruction,
    do:
      "Actúa por cualquier monstruo/PNJ cuyo turno sea. " <>
        "Si los jugadores han pedido algo concreto (combate, explorar, hablar con un PNJ), " <>
        "EJECÚTALO ahora: usa spawn_monster si piden pelea, narra lo que encuentran si exploran, " <>
        "responde si preguntan. NO narres que un PNJ 'espera' o 'no responde' — haz que ACTÚE. " <>
        "Si la escena lleva parada más de un turno, introduce algo NUEVO (enemigo, evento, revelación). " <>
        "NO repitas la misma descripción de escena. Narra en 1-3 frases y responde en castellano."

  # Special DM instruction fired when we detect post-combate limbo — combate
  # ended but the timeline hasn't moved past it. The DM is FORCED to advance:
  # invoke a new threat, change scene, introduce a PNJ with news. The "¿qué
  # hacéis?" open question is explicitly banned here because that's exactly
  # what creates the loop where every PC re-declares "seguimos con lo siguiente".
  defp dm_post_combat_instruction,
    do:
      "⚠️ AVANCE OBLIGATORIO ⚠️ El combate acaba de terminar y la partida está ATASCADA " <>
        "pidiendo a los jugadores '¿qué hacéis?' en bucle. ESTE TURNO DEBES AVANZAR LA " <>
        "ESCENA, NO abrir la pregunta al grupo. Elige UNA de estas opciones y EJECÚTALA:\n" <>
        "1. spawn_monster(\"<kind>\", \"<name>\") — una nueva oleada/hostil aparece (si la biblia " <>
        "lo permite: goblin, kobold, skeleton, orc, wolf, training_dummy...).\n" <>
        "2. Un PNJ llega con noticias o un nuevo encargo (narrado + diálogo del PNJ).\n" <>
        "3. set_scene(\"<nueva localización o situación>\") — la party es trasladada a otra " <>
        "zona (biblioteca, taberna, mazmorra, lo que dicte la biblia).\n" <>
        "4. Un evento ambiental: la puerta cede, suena una alarma, llega el anochecer...\n\n" <>
        "NUNCA termines este turno con '¿qué hacéis?' o '¿qué deseáis hacer?'. " <>
        "Sé BREVE (2-4 frases): describe el nuevo elemento y TERMINA. Los PCs reaccionarán " <>
        "en sus turnos. Responde en castellano."

  # Exploration-stall avance: the partida has been cycling through pure narration
  # with nobody acting (no checks, no spawns, no scene changes). The DM is forced
  # to break the statu quo itself rather than re-asking "¿qué hacéis?". Similar
  # in spirit to the post-combate instruction but pitched for a stalled
  # exploration scene.
  defp dm_advance_instruction,
    do:
      "⚠️ AVANCE OBLIGATORIO ⚠️ La escena lleva VARIOS turnos sin progreso: todo el grupo " <>
        "narra y re-declara intenciones ('¿empezamos con X?', '¿vamos a Y?') pero NADIE actúa. " <>
        "ESTE TURNO DEBES ROMPER EL STATU QUO y mover la partida. NO abras con '¿qué hacéis?'. " <>
        "Elige UNA opción y EJECÚTALA:\n" <>
        "1. spawn_monster(\"<kind>\", \"<name>\") — una amenaza irrumpe y FUERZA el combate " <>
        "(goblin, kobold, skeleton, orc, wolf… lo que dicte la biblia).\n" <>
        "2. Un PNJ llega o reacciona con información/urgencia que exija respuesta inmediata.\n" <>
        "3. set_scene(\"<nueva localización o situación>\") — traslada al grupo a otra zona.\n" <>
        "4. Un evento ambiental que cambie las condiciones (la puerta cede, suena una alarma, " <>
        "cruje el suelo, se apagan las antorchas…).\n" <>
        "5. Si un PC pidió algo concreto en su último turno, RESUÉLVELO ahora (ability_check, " <>
        "lo que encuentran al investigar, la respuesta del PNJ).\n\n" <>
        "Sé BREVE (2-3 frases): introduce el cambio y TERMINA. Los PCs reaccionarán después. " <>
        "Responde en castellano."

  # True when the most recent :system "El combate termina" marker hasn't been
  # followed by any meaningful advancement (a new spawn_monster, set_scene, or
  # at least a narration that introduces a new element). We look back at the
  # last few events: if the combate-end is the most recent :system AND there
  # are no more than 2 narration events since, we're in limbo.
  defp post_combat_limbo?(game_id) do
    events = Games.recent_events(game_id, 12)

    # Find the index of the most recent "El combate termina" system event.
    end_idx =
      events
      |> Enum.with_index()
      |> Enum.find_value(fn {e, idx} ->
        if e.type == :system and combat_end_note?(e.payload), do: idx
      end)

    if end_idx do
      # Count narrations + actions AFTER the combate-end marker. If 0 or just
      # the immediate aftermath, we're in limbo. Allow up to 3 narrations
      # (the post-combate reactions of each PC) before declaring the limbo
      # over — by then the DM should have moved on.
      events_after = Enum.drop(events, end_idx + 1)

      narrations_after =
        Enum.count(events_after, fn e -> e.type in [:narration, :action] end)

      # Also check that no scene-setting tool ran after the combate ended.
      scene_moved? =
        Enum.any?(events_after, fn e ->
          e.type == :system and (e.payload["note"] || "") =~ ~r/escena cambiada|set_scene/i
        end)

      narrations_after <= 4 and not scene_moved?
    else
      false
    end
  end

  defp combat_end_note?(%{"note" => note}) when is_binary(note),
    do: note =~ "El combate termina" or note =~ "combate termina"

  defp combat_end_note?(_), do: false

  # ---------------------------------------------------------------------------
  # Bug #4 — the DM sometimes narrates a PC acting on its behalf ("*Lyra
  # desenvaina y ataca*"). Rule 14 forbids this but the model still leaks. When
  # the DM's most recent narration matches "<pc-name> <action-verb>" in the same
  # clause, we reinforce rule 14 on the NEXT DM instruction. We DON'T scrub the
  # offending text (that risks mangling legitimate narration like "Lyra cae
  # herida"); a targeted reminder is enough to correct course on the next beat.
  @puppet_action_verbs ~w(
    ataca ataco atacar ataque
    lanza lanzo lanzar
    conjura conjuro conjurar
    golpea golpeo golpear
    dispara disparo disparar
    desenvaina desenvainar
    carga cargo cargar
    salta salto saltar
    corre correr
    persigue perseguir
    hechiza hechizar
    arremete arremeter
    embiste embestir
    invoca invocar
    avanza avanzar
    sube subir baja bajar
    entra entrar sale salir
    mueve mover
    abre abrir cierra cerrar
    empuja empujar tira tirar
    agarra coge toma deja
    gira voltea
    examina examinar inspecciona inspeccionar
    busca buscar registra estudia
    dice hablar habla
    grita susurrar susurra
    pregunta preguntar responde responder exclama replica
  )

  defp with_dm_no_puppet_nudge(game_id, world, base_instruction) do
    if dm_puppeted_a_pc?(game_id, world) do
      Logger.info("dragones game #{game_id} DM narrated a PC acting — reinforcing rule 14")
      dm_no_puppet_nudge() <> "\n\n" <> base_instruction
    else
      base_instruction
    end
  end

  defp dm_puppeted_a_pc?(game_id, %Dragones.World{} = world) do
    pc_names = living_pc_names(world)

    if pc_names == [] do
      false
    else
      case last_dm_narration(game_id) do
        nil -> false
        text -> Regex.match?(puppet_pattern(pc_names), text)
      end
    end
  end

  # The DM's narration texts, most recent first. We sort by `seq` descending
  # explicitly (rather than relying on `recent_events`'s query order) so the
  # ordering is unambiguous regardless of how the query returns rows. Shared by
  # the anti-puppet check (needs the latest) and the anti-repeat check (needs
  # the last two).
  defp dm_narration_texts(game_id) do
    game_id
    |> Games.recent_events(20)
    |> Enum.filter(fn e -> e.type == :narration and e.actor == "dm" end)
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.map(fn e -> e.payload["text"] || "" end)
    |> Enum.reject(&(&1 == ""))
  end

  defp last_dm_narration(game_id), do: List.first(dm_narration_texts(game_id))

  defp living_pc_names(%Dragones.World{characters: chars}) do
    chars
    |> Enum.filter(fn {_, c} -> c.side == "pc" and (c.hp || 0) > 0 end)
    |> Enum.map(&elem(&1, 0))
  end

  # Build a regex that matches a PC name followed (within one clause, ~50 chars)
  # by a proactive action verb, OR a verb followed by a PC. Anchored on word
  # boundaries so "Thane" doesn't match "Thanelong" and vice-versa.
  defp puppet_pattern(pc_names) do
    names_alt = pc_names |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    verbs_alt = @puppet_action_verbs |> Enum.join("|")
    pattern = "(?:\\b#{names_alt}\\b)[^.!?]{0,50}\\b(?:#{verbs_alt})\\b|(?:\\b#{verbs_alt}\\b)[^.!?]{0,30}(?:\\b#{names_alt}\\b)"

    case Regex.compile(pattern, "i") do
      {:ok, re} -> re
      {:error, _} -> ~r/^$/
    end
  end

  defp dm_no_puppet_nudge do
    "⚠️ REGLA 14 — RECORDATORIO URGENTE ⚠️ En tu ÚLTIMA narración describiste a un " <>
      "personaje jugador (PC) HACIENDO algo: atacar, moverse, conjurar, hablar, desenvainar… " <>
      "ESTÁ PROHIBIDO narrar las acciones, decisiones o diálogos de los PCs. Ellos actúan en " <>
      "SU turno; tú NUNCA los mueves, los haces hablar, ni decides por ellos. Tu narración " <>
      "describe SOLO el mundo, los monstruos, los PNJ y las consecuencias de lo que YA ocurrió. " <>
      "Si un PC aún no ha actuado, ESPERA — no rellenes con su comportamiento."
  end

  # DM anti-repeat: when the DM reuses nearly the same line ("se desvanece en
  # una nube de humo sulfúrico" x N) it reads as a broken record. We compare the
  # last two DM narrations and, on a near-duplicate (Jaccard >= 0.7), force a
  # freshly-worded description this turn. Mirrors the PC anti-loop, but pitched
  # for narration variety rather than forcing a different action.
  @dm_repeat_threshold 0.7

  defp with_dm_anti_repeat(game_id, base_instruction) do
    case dm_narration_texts(game_id) do
      [a, b | _] when is_binary(a) and is_binary(b) ->
        if text_similarity(a, b) >= @dm_repeat_threshold do
          Logger.info("dragones game #{game_id} DM repeating narration — enforcing variety")
          dm_anti_repeat_nudge(a, base_instruction)
        else
          base_instruction
        end

      _ ->
        base_instruction
    end
  end

  defp dm_anti_repeat_nudge(last_text, base) do
    snippet = String.slice(String.trim(last_text), 0, 120)

    "⚠️ EVITA REPETIRTE ⚠️ Tu narración anterior fue prácticamente: «#{snippet}». " <>
      "NO reutilices esas mismas palabras ni esa misma imagen. Esta vez describe la " <>
      "escena, la criatura o la acción con un lenguaje y un enfoque NUEVOS y vívidos: " <>
      "cambia el detalle sensorial (olor, sonido, luz), el ángulo de la cámara, o el " <>
      "rasgo que destacas. Varía el ritmo y el vocabulario. Sé breve, pero fresco.\n\n" <>
      base
  end

  # Ghost combat v2: the DM narrates "aparece un esqueleto" / "se materializa un
  # demonio" but never calls spawn_monster, so no enemy exists in the World and
  # maybe_force_combat can't fire. The partida loops with the DM re-narrating
  # the appearance every turn. When the DM's last narration describes a hostile
  # appearing while we're in exploration with NO living enemies at all, we nudge
  # it to actually spawn the creature (the engine then forces initiative).
  @hostile_appear_verbs ~w(aparece aparecen materializa materializan irrumpe irrumpen surge surgen emerge emergen brota salen asoma asoman conjura invoca)
  @hostile_creatures ~w(goblin kobold bandit skeleton esqueleto wolf lobo orc orco hobgoblin ogre imp demonio diablillo diablo espinodemonio espinodemon trasgo draco dragon no-muerto muerto-viviente zombi zombie criatura monstruo bestia engendro siervo esbirro aberracion aberración elemental gargola gárgola licantropo licántropo vampiro espectro fantasma wraith)

  defp with_dm_unspawned_hostile_nudge(game_id, %Dragones.World{phase: :exploration} = world, base) do
    enemies = living_enemies(world)

    if MapSet.size(enemies) == 0 do
      case last_dm_narration(game_id) do
        nil ->
          base

        text ->
          if narrates_hostile_appearing?(text) do
            Logger.info(
              "dragones game #{game_id} DM narrated a hostile appearing without spawn_monster — nudging"
            )

            dm_spawn_nudge(base)
          else
            base
          end
      end
    else
      base
    end
  end

  defp with_dm_unspawned_hostile_nudge(_game_id, _world, base), do: base

  defp narrates_hostile_appearing?(text) do
    verbs = @hostile_appear_verbs |> Enum.join("|")
    creatures = @hostile_creatures |> Enum.join("|")
    pattern = "(?:#{verbs})\\b[^.!?]{0,40}\\b(?:#{creatures})\\b"

    case Regex.compile(pattern, "i") do
      {:ok, re} -> Regex.match?(re, text)
      {:error, _} -> false
    end
  end

  defp dm_spawn_nudge(base) do
    "⚠️ HOSTIL SIN SPAWN ⚠️ En tu última narración describiste que un hostil aparece, " <>
      "pero NO existe en el mundo (no llamaste spawn_monster). ESTE TURNO DEBES materializarlo " <>
      "con spawn_monster(\"<kind>\", \"<nombre>\") — kinds disponibles: goblin, kobold, bandit, " <>
      "skeleton, wolf, orc, hobgoblin, ogre, training_dummy, archery_target — y el motor " <>
      "tirará iniciativa automáticamente. Si NO quieres combate real, NO narres que un hostil " <>
      "aparece: describe solo el entorno o un PNJ no hostil.\n\n" <> base
  end

  # Language guard. DeepSeek-v4-flash occasionally drifts into English for a
  # whole paragraph even though the system prompt says "responde en castellano".
  # We flag it by counting clearly-English stopwords (the/and/was/were/…) that
  # don't occur in normal Spanish prose; on a hit we reinforce the language rule
  # for the next beat. Conservative list: every marker here is unambiguously
  # English (no false friends with common Spanish words).
  @english_markers MapSet.new(~w(
    the and was were has have had will would should could might must shall
    this that these those they them their theirs its our ours your yours
    been being into onto upon about against through during before after without
    himself herself itself ourselves yourselves themselves there here from with
  ))

  defp with_dm_spanish_nudge(game_id, base) do
    case last_dm_narration(game_id) do
      nil ->
        base

      text ->
        if looks_english?(text) do
          Logger.info("dragones game #{game_id} DM drifted into English — enforcing Spanish")
          dm_spanish_nudge(base)
        else
          base
        end
    end
  end

  defp dm_spanish_nudge(base) do
    "⚠️ IDIOMA ⚠️ Tu última narración contenía frases en INGLÉS. " <>
      "DEBES narrar, describir y dialogar EXCLUSIVAMENTE en CASTELLANO. " <>
      "Reescribe cualquier término, descripción o línea de diálogo en español. " <>
      "El inglés SOLO está permitido para nombres propios de lugares o personas que la biblia " <>
      "defina explícitamente en ese idioma; todo lo demás, en castellano.\n\n" <> base
  end

  # True when a text carries enough clearly-English function words to read as
  # English (threshold 5 — a Spanish paragraph almost never hits even 2).
  defp looks_english?(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\s]/u, " ")
      |> String.split(~r/\s+/, trim: true)

    Enum.count(words, &MapSet.member?(@english_markers, &1)) >= 5
  end

  # Exploration stall: a long run of pure narration with NO mechanical progress
  # (no ability check → :dice, no player declaration → :action, no spawn/scene →
  # :system note, no combat start). This is the "¿empezamos con el círculo?" x 10
  # turns pattern where everyone keeps re-declaring intentions without anyone
  # acting. When it hits, the DM is forced to advance the scene itself. Only
  # fires in exploration (combat has its own end-combat path) and only once a
  # meaningful backlog of narration has piled up, so a couple of scene-setting
  # lines right after setup don't trip it.
  defp exploration_limbo?(game_id, %Dragones.World{phase: :exploration}) do
    recent =
      game_id
      |> Games.recent_events(20)
      |> Enum.reject(fn e -> e.type in [:turn] end)
      |> Enum.take(8)

    # Need enough history to call it a stall (not a fresh partida), and every
    # recent meaningful event must be bare narration — any :dice, :action or
    # scene/spawn :system in the window means someone made progress.
    length(recent) >= 6 and Enum.all?(recent, &narration_only?/1)
  end

  defp exploration_limbo?(_, _), do: false

  defp narration_only?(%{type: :narration}), do: true
  defp narration_only?(%{type: :system, payload: %{"note" => note}})
       when is_binary(note),
       do: not (note =~ ~r/escena cambiada|set_scene|spawn|toma la iniciativa|combate/i)
  defp narration_only?(%{type: :system}), do: true
  defp narration_only?(_), do: false

  # ---------------------------------------------------------------------------
  # PC anti-loop: detect when an AI PC re-declares the same non-action turn
  # after turn ("¿subimos al círculo?" x N, "voy a calentar el brazo" x N) and
  # force a different concrete action. The system prompt already forbids this,
  # but prompts alone weren't enough — so we compare the bot's last two
  # narrations and, on a near-duplicate, stitch a hard nudge onto the instruction.
  # Jaccard similarity over word sets (>0.75) catches verbatim repeats and light
  # reformulations without firing on legitimately related turns.
  @pc_stopwords MapSet.new(~w(el la los las un una unos unas de del a al en y o u que se su sus es son por para con sin como mas pero si no ya yo tu él me te le nos os les esto eso aque mi tu sus nuestrouestra al acabo apenas cuando donde mientras tras etecera))
  @pc_repeat_threshold 0.75

  defp with_pc_anti_loop(game_id, current, base_instruction) do
    case pc_repetition(game_id, current) do
      {:repeating, last_text} ->
        Logger.info("dragones game #{game_id} PC #{current} stuck in a loop — injecting anti-loop nudge")
        pc_anti_loop_nudge(last_text, base_instruction)

      :ok ->
        base_instruction
    end
  end

  # Pull the last two :narration events by this actor and flag a repeat if the
  # texts are highly similar. Ignores tool-only turns (no narration) and the
  # very first turn (nothing to compare against).
  defp pc_repetition(game_id, current) do
    texts =
      game_id
      |> Games.recent_events(40)
      |> Enum.filter(fn e -> e.type == :narration and e.actor == current end)
      |> Enum.map(fn e -> e.payload["text"] || "" end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(2)

    case texts do
      [a, b] when is_binary(a) and is_binary(b) ->
        if text_similarity(a, b) >= @pc_repeat_threshold, do: {:repeating, a}, else: :ok

      _ ->
        :ok
    end
  end

  defp pc_anti_loop_nudge(last_text, base) do
    snippet = String.slice(String.trim(last_text), 0, 140)

    "⚠️ ANTIBUCLE DETECTADO ⚠️ En tu último turno dijiste prácticamente lo mismo: «#{snippet}». " <>
      "ESTÁ PROHIBIDO repetir o reformular esa misma intención, pregunta o declaración de propósitos. " <>
      "ESTE TURNO DEBES hacer algo DISTINTO y CONCRETO que la partida aún no haya visto: " <>
      "caminar hacia una salida/puuesta/objeto, abrir o inspeccionar algo físico, hablar con un PNJ " <>
      "mencionado por el DM, usar ability_check(\"<tu nombre>\", \"<str|dex|int|wis|cha>\", <DC>) para " <>
      "intentar algo con riesgo real, o proponer y EJECUTAR una acción nueva en una o dos frases. " <>
      "Si la vía anterior no avanza, CAMBIA de enfoque. Responde en castellano.\n\n" <>
      base
  end

  # Jaccard similarity over normalized word sets. Robust to punctuation,
  # accents, and casing; stopwords are dropped so short function words don't
  # inflate the score. Returns 0.0 for empty inputs.
  defp text_similarity(a, b) do
    set_a = tokenize(a)
    set_b = tokenize(b)

    if MapSet.size(set_a) == 0 or MapSet.size(set_b) == 0 do
      0.0
    else
      inter = MapSet.intersection(set_a, set_b) |> MapSet.size()
      union = MapSet.union(set_a, set_b) |> MapSet.size()
      inter / union
    end
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&MapSet.member?(@pc_stopwords, &1))
    |> MapSet.new()
  end

  # Engine-driven combat resolution. The DM used to be solely responsible for
  # calling end_combat when every enemy was down — and frequently forgot, leaving
  # the loop cycling turns through dead enemies. Now the engine ends combat the
  # moment `World.combat_over?/1` is true (at most one conscious side left).
  defp maybe_end_combat(state) do
    world = Session.read_state(state.session)

    if world.phase == :combat and Dragones.World.combat_over?(world) do
      with next when not is_nil(next) <- Session.current(state.session),
           {:ok, _} <- Session.update_state(state.session, next, Dragones.World.end_combat()) do
        {:ok, _} =
          Games.append_event(state.game_id, :system, "system", "all", %{note: "⚔ El combate termina."})
      end
    end

    state
  end

  # Ghost-combat recovery. When the DM brings a new living enemy into the scene
  # (spawn_monster) during exploration but never rolls initiative, the partida
  # used to stall: the DM would re-narrate "aparece un esqueleto" turn after
  # turn while the loop stayed in exploration, burning 4-5 turns of false-start
  # combat before initiative finally fired. Here the engine detects that a beat
  # INTRODUCED a hostile (enemies_after has names enemies_before didn't) while
  # the world is still in exploration, and forces a roll_initiative itself so the
  # fight is sequenced immediately. Comparing before/after — rather than acting
  # on the mere presence of enemies — avoids false positives at partida start
  # (where monsters may already be in the world during the scene-setting beat).
  defp maybe_force_combat(state, enemies_before) do
    world = Session.read_state(state.session)

    newly_hostile =
      world
      |> living_enemies()
      |> MapSet.difference(enemies_before)

    cond do
      world.phase != :exploration ->
        state

      MapSet.size(newly_hostile) == 0 ->
        state

      not has_living_pcs?(world) ->
        # Nobody to fight back — don't start combat against an empty party.
        state

      true ->
        {:ok, _msg, change} = Dragones.Actions.initiative(world, state.roller)

        with next when not is_nil(next) <- Session.current(state.session),
             {:ok, _} <- Session.update_state(state.session, next, change) do
          {:ok, _} =
            Games.append_event(state.game_id, :system, "system", "all", %{
              note: "⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente."
            })

          Logger.info(
            "dragones game #{state.game_id} forced combat start after new enemies: #{inspect(MapSet.to_list(newly_hostile))}"
          )
        end

        state
    end
  end

  defp living_enemies(%Dragones.World{characters: chars}) do
    chars
    |> Enum.filter(fn {_, c} -> c.side == "enemy" and (c.hp || 0) > 0 end)
    |> Enum.map(fn {name, _} -> name end)
    |> MapSet.new()
  end

  defp has_living_pcs?(%Dragones.World{characters: chars}) do
    Enum.any?(chars, fn {_, c} -> c.side == "pc" and (c.hp || 0) > 0 end)
  end

  # Advance the round counter when the initiative cycle wraps. A round = one
  # full pass through the (living) combatants; we detect the wrap statelessly:
  # the participant who just acted was the LAST in the cycle and there's more
  # than one combatant. `beat_phase` excludes the combat-START beat (which began
  # in exploration and may falsely look like a wrap). No-op once combat has
  # ended above. Keeps `world.round` honest so the DM brief stays accurate.
  defp maybe_advance_round(state, acted, :combat) do
    world = Session.read_state(state.session)

    if world.phase == :combat do
      cycle = Dragones.TurnPolicy.WorldDriven.combat_participants(world, "dm")

      if length(cycle) > 1 and acted == List.last(cycle) do
        with next when not is_nil(next) <- Session.current(state.session),
             {:ok, _} <- Session.update_state(state.session, next, Dragones.World.next_round()) do
          :ok
        end
      end
    end

    :ok
  end

  defp maybe_advance_round(_state, _acted, _beat_phase), do: :ok

  # Persist the live state to Postgres: world jsonb + turn position + status +
  # the pending intents (so a player's declared plan survives a restart).
  defp persist(state, status) do
    world = Session.read_state(state.session)

    Games.save_state(
      state.game_id,
      world,
      Session.current(state.session),
      world.round,
      status,
      state.intents
    )
  end

  # --------------------------------------------------------------- pubsub

  # The Game owns a single "something changed" signal on Dragones.PubSub. The
  # LiveView subscribes and re-fetches the snapshot — it never polls and never
  # touches the Repo directly. Topic is per partida.
  @pubsub Dragones.PubSub

  defp topic(game_id), do: "dragones:game:#{game_id}"

  # Broadcast that the partida changed (beat finished, status flip, human acted).
  # Best-effort: a pubsub hiccup must never break the loop.
  defp broadcast_updated(%__MODULE__{game_id: game_id}) do
    Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:game_updated, game_id})
  rescue
    _ -> :ok
  end

  defp broadcast_updated(game_id) when is_integer(game_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:game_updated, game_id})
  rescue
    _ -> :ok
  end

  # One roll group landed just now (RollLog on_close). Push it to the dice modal
  # immediately with the full labeled entry (reason + dice + total + against +
  # outcome) so the modal opens exactly once per roll, with everything in one
  # shot — not the bare-number-then-context two-step we used to have.
  defp broadcast_roll_group(game_id, entry) do
    Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:dice_group, game_id, entry})
  rescue
    _ -> :ok
  end

  # --------------------------------------------------------------- model

  defp default_model, do: Dragones.Models.dm()

  # Token streaming is only meaningful for real HTTP-backed providers. The
  # in-process Test model can't propagate its mutated script index back through
  # `request_stream`, so streaming it would loop on the same script item
  # forever. Anything that isn't the Test model gets the live-preview path.
  defp stream_text_for(%ExAgent.Models.Test{}), do: false
  defp stream_text_for(_), do: true

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      s -> String.to_integer(s)
    end
  end
end
