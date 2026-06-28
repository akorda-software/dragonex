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
            busy: nil

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
        compaction_threshold: env_int("DRAGONES_COMPACTION_THRESHOLD", 6000),
        compaction_keep_recent: env_int("DRAGONES_COMPACTION_KEEP_RECENT", 8)
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
          agent = PCAgent.new(model, character, max_tokens: 384)

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
          agent = PCAgent.new(state.model, character, max_tokens: 384)

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
  end

  # A beat Task finished successfully.
  def handle_info({ref, result}, %{busy: busy} = state) do
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
            instruction = PCAgent.instruction(current, character || Dragones.Character.new(name: current), world)
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

            state = run_beat(state, current, dm_instruction(), turn_id, world)
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

        # Engine-driven combat bookkeeping the DM used to have to remember (and
        # often forgot, leaving combat wedged or the round counter stuck):
        state = maybe_end_combat(state)
        maybe_advance_round(state, current, beat_phase)

        persist(state, :running)
        broadcast_updated(state)
        send(self(), @tick)
        %{state | status: :running}

      {:error, reason} ->
        # A beat can fail for many reasons: the bot/DM burned its tool retry
        # budget (typically by attacking a non-existent target), the model hit
        # max_tokens mid-narration, an unexpected provider error… Pausing the
        # partida here is the worst choice — it leaves the player stuck pressing
        # "reanudar" only to hit the same failure again. Instead, log the cause
        # for diagnosis, surface a soft in-fiction beat that lets the loop move
        # on, and advance the turn. Real crashes still kill the Task (handled
        # by the :DOWN clause), so we're not masking process deaths here.
        Logger.warning("dragones game #{state.game_id} beat failed: #{inspect(reason)}")

        {:ok, _} =
          Games.append_event(state.game_id, :system, "system", "dm", %{
            note: "el turno falló: #{inspect(reason)}"
          })

        # Fallback narration so the timeline isn't gap-toothed. Voice it as
        # the actor when it's a PC bot, as the DM otherwise.
        fallback = fallback_narration(current, reason)
        {:ok, _} = Games.append_event(state.game_id, :narration, current, "all", %{text: fallback})

        {:ok, _} = Session.end_turn(state.session, current)

        state = maybe_end_combat(state)
        maybe_advance_round(state, current, beat_phase)

        persist(state, :running)
        broadcast_updated(state)
        send(self(), @tick)
        %{state | status: :running}
    end
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
  defp run_beat(%{session: session, roller: roller, game_id: game_id} = state, participant, instruction, turn_id, world) do
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
          case Server.chat(agent, prompt, deps: deps, stream_text: stream?) do
            {:ok, %{output: narration, usage: usage}} ->
              {:ok, narration, RollLog.entries(recorder), usage}

            {:error, reason} ->
              {:error, reason}
          end

        RollLog.stop(recorder)
        result
      end)

    %{state | busy: %{ref: task.ref, participant: participant, phase: world.phase, turn_id: turn_id}}
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
      "Actúa por cualquier monstruo/PNJ cuyo turno sea (llama a las herramientas), luego narra. " <>
        "Haz avanzar la escena. Responde en castellano."

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
