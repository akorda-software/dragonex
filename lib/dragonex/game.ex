defmodule Dragonex.Game do
  @moduledoc """
  The process that owns one partida's turn loop — the application layer above the
  `ExAgent.Session` motor.

  The Game is the **single source of durability**: after every beat it persists
  the live `Dragonex.World` (jsonb via Codec), the turn position and an appended
  event to Postgres. The `ExAgent.Session` runs in-memory as the engine; if the
  Game process dies, a fresh one rehydrates the same `game_id` from Postgres and
  resumes exactly where it left off.

  ## The loop (D25)

  Micro-machine **actor → turnmaster → handoff**:

    * **TurnMaster beat** — cheap agent decides who acts next (`give_turn_to`,
      `cut_in`, `react`, `pass_to_dm`, `end_scene`). Tools only **record** the
      decision; this GenServer applies it via `Session.handoff/2` /
      `Session.update_state/3` (single-writer, D6). On failure → `WorldDriven`
      fallback.
    * **AI actor turn** (DM or AI PC) → agent beat in a **Task**. On success,
      do **not** `end_turn`; hand the floor to TurnMaster.
    * **Human turn** → `:waiting` until `declare/3`; then the same actor→TM pair.

  `controlled_by?` still enforces that only the current actor uses resolution
  tools. `WorldDriven` remains the Session policy and the safety net.

  ## Collaborators (extracted modules)

  All of them run **inside this GenServer's process** (single-writer, D6):

    * `Dragonex.Game.Bootstrap`    — rehydrates the engine + agents from Postgres.
    * `Dragonex.Game.Beats`        — launches actor/TurnMaster beats as Tasks.
    * `Dragonex.Game.Settlement`   — settles beat results (success, fallbacks, retries).
    * `Dragonex.Game.Turnmaster`   — applies TM decisions + WorldDriven fallback.
    * `Dragonex.Game.Combat`       — engine-driven combat/round bookkeeping.
    * `Dragonex.Game.Persistence`  — Postgres snapshots + PubSub broadcasts.
    * `Dragonex.Game.Participants` — roster predicates (human? / ai_pc? / …).

  ## Restart / rehydrate

  On `init`, the Game loads its row from Postgres, decodes the world, rebuilds
  the Session, and `handoff`s to the stored `current_participant`. Fresh games
  open on the TurnMaster phase; resumed games open on `:actor`.
  """

  use GenServer
  require Logger

  alias Dragonex.{Games, Intents}

  alias Dragonex.Game.{
    Beat,
    Bootstrap,
    Beats,
    Participants,
    Persistence,
    PendingRetry,
    Settlement,
    Turnmaster
  }

  alias Dragonex.Game.Guardrails
  alias Dragonex.Game.Instructions
  alias ExAgent.Session

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
            # TurnMaster agent server (D25) — decides who acts next.
            turnmaster: nil,
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
            fallback_streak: 0,
            # Micro-machine phase of the actor→turnmaster pair (D25).
            # :actor runs DM/PC; :turnmaster runs the handoff agent.
            loop_phase: :turnmaster,
            # Who just finished an actor beat (fed into the TurnMaster brief).
            last_actor: nil,
            # Whether the last actor beat was a mini-turn (cut_in/react).
            last_was_mini: false,
            # Actor interrupted by cut_in/react — brief nudges TM to return.
            interrupted: nil,
            # Anti-loop: consecutive give_turn_to of the same actor.
            tm_same_actor_streak: 0,
            # Circuit breaker for hard TurnMaster failures.
            tm_fallback_streak: 0,
            # Optional nudge stitched into the next TM instruction.
            tm_nudge: nil,
            # Next actor beat is a mini-turn (cut_in/react) — do not mark
            # acted_this_round when it settles.
            pending_mini: false,
            # Signature of the intents map that last triggered a TM re-eval
            # while parked on another human (anti-spam: same text → no-op).
            tm_intent_sig: nil,
            # True while the current TM beat was kicked off by an off-turn
            # declare during :waiting. Fallback must NOT steal the waiter's
            # floor (WorldDriven end_turn would skip them).
            tm_reeval: false

  # --------------------------------------------------------------- API

  @doc """
  Start a Game process for `game_id`, rehydrating from Postgres. Options:

    * `:model`  — the LLM model for the DM agent (defaults to env/provider config in `Dragonex.Models`).
    * `:roller` — a `(sides -> value)` dice fn (defaults to `Dragonex.Dice.roll`).
  """
  @spec start_link({term(), keyword()}) :: GenServer.on_start()
  def start_link({game_id, opts}),
    do:
      GenServer.start_link(__MODULE__, {game_id, opts},
        name: Dragonex.Game.Supervisor.via(game_id)
      )

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
    case Dragonex.Game.Supervisor.whereis(game_id) do
      nil -> Dragonex.Game.Supervisor.start_game(game_id, opts)
      pid -> {:ok, pid}
    end
  end

  @doc """
  Restart the Game process for `game_id` (stop + rehydrate from Postgres).

  Used by the Ajustes modal to apply a provider/model/thinking change: the model
  is baked into the DM agent at start, so a config change needs a fresh process
  to pick it up. The partida's world + turn position are persisted, so it
  resumes at the same point with the new model wired in. Any in-flight beat is
  discarded (its pre-beat state was already persisted).
  """
  @spec restart(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def restart(game_id, opts \\ []) do
    _ = Dragonex.Game.Supervisor.stop_game(game_id)

    # terminate_child is synchronous, but the Registry drops the key
    # asynchronously on the process :DOWN. If we start immediately, ensure_started
    # can see the stale (dead) pid and skip starting a fresh Game — leaving no
    # live process and the LiveView stuck on "Cargando partida…". Poll briefly
    # until the key is gone, then start a brand new process.
    wait_until_gone(game_id)

    case Dragonex.Game.Supervisor.start_game(game_id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp wait_until_gone(game_id), do: wait_until_gone(game_id, 100)
  defp wait_until_gone(_game_id, 0), do: :ok

  defp wait_until_gone(game_id, n) do
    case Dragonex.Game.Supervisor.whereis(game_id) do
      nil ->
        :ok

      _ ->
        Process.sleep(5)
        wait_until_gone(game_id, n - 1)
    end
  end

  @doc "The participant whose turn it is."
  @spec current(GenServer.server()) :: term() | nil
  def current(server), do: GenServer.call(server, :current)

  @doc "The live world (struct)."
  @spec world(GenServer.server()) :: Dragonex.World.t()
  def world(server), do: GenServer.call(server, :world)

  @doc "The Game process status (`:running | :waiting | :paused | :ended`)."
  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @doc "A snapshot for rendering: world, current, status, round."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc """
  Sincroniza una subida de nivel del héroe al `Character` vivo de la partida,
  **dentro del GenServer** (respeta el single-writer): aplica el merge al `World`
  del Session, actualiza el snapshot `characters.sheet`, persiste y avisa por
  PubSub. Es la vía correcta desde el LiveView de level-up cuando la partida
  está corriendo (evita que el siguiente `persist` pise el cambio).
  """
  @spec sync_hero_level_up(GenServer.server(), term(), Dragonex.Character.t()) ::
          :ok | {:error, :not_found | :sync_failed}
  def sync_hero_level_up(server, hero_id, %Dragonex.Character{} = new_sheet) do
    GenServer.call(server, {:sync_hero_level_up, hero_id, new_sheet})
  end

  @doc """
  A human **declares** an action as `participant` — anytime, even off-turn.

  The intent is recorded (so the partida keeps its plan across a restart). If it
  happens to be that participant's turn right now (and nothing is in flight), the
  Game resolves it immediately; otherwise it is queued and the loop resolves it
  when the turn arrives. The DM then *values* it on resolution — a valid action
  resolves through the tools; an impossible/contradictory one is narrated away or
  ignored by the engine's control guard.
  """
  @spec declare(GenServer.server(), term(), String.t()) ::
          {:ok, :resolving | :queued} | {:error, term()}
  def declare(server, participant, text),
    do: GenServer.call(server, {:declare, participant, text})

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
      :done ->
        :ok

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: :timeout,
          else:
            (
              Process.sleep(10)
              nil
            )
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
      :done ->
        :ok

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: :timeout,
          else:
            (
              Process.sleep(10)
              nil
            )
    end)
  end

  # --------------------------------------------------------------- init

  @impl true
  def init({game_id, opts}) do
    case Games.get_game(game_id) do
      nil ->
        {:stop, {:not_found, game_id}}

      %Games.Game{} = game ->
        state = Bootstrap.rehydrate(game_id, game, opts)
        send(self(), @tick)
        {:ok, state}
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
      intents: Intents.display(state.intents),
      # Human participants currently auto-played by an agent (so the toggle
      # reflects real engine state across reloads / multiple tabs).
      auto: Participants.auto_humans(state),
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
      not Participants.human?(state, participant) ->
        {:reply, {:error, :not_your_turn}, state}

      text == "" ->
        # Empty declare clears any prior intent.
        intents = Map.delete(state.intents, participant)
        Games.save_intents(state.game_id, intents)
        {:reply, {:ok, :queued}, %{state | intents: intents}}

      true ->
        # Record the intent (durable) so it survives a restart / off-turn wait.
        world = Session.read_state(state.session)
        intents = Intents.put(state.intents, participant, text, world.phase)
        Games.save_intents(state.game_id, intents)
        state = %{state | intents: intents}

        # Resolve immediately if it's this participant's turn and idle.
        can_resolve_now? =
          state.status == :waiting and state.busy == nil and current == participant

        if can_resolve_now? do
          # Live resolution: append the :turn marker first so the consumed
          # intent and the ensuing beat share the same turn_id (matches the
          # loop path through advance/1).
          turn_id = Beats.generate_turn_id()
          world = Session.read_state(state.session)
          Beats.append_turn_marker(state.game_id, participant, turn_id, world)
          state = Beats.consume_intent(state, participant, turn_id, world)
          Persistence.broadcast_updated(state)
          {:reply, {:ok, :resolving}, state}
        else
          state = maybe_reeval_turnmaster(state, participant)
          Persistence.broadcast_updated(state)
          {:reply, {:ok, :queued}, state}
        end
    end
  end

  def handle_call({:clear_intent, participant}, _from, state) do
    intents = Map.delete(state.intents, participant)
    Games.save_intents(state.game_id, intents)
    Persistence.broadcast_updated(%{state | intents: intents})
    {:reply, :ok, %{state | intents: intents}}
  end

  def handle_call(:pause, _from, %{status: status} = state) when status in [:running, :waiting] do
    {:ok, _} = Games.set_status(state.game_id, :paused)
    Persistence.broadcast_updated(state)
    {:reply, :ok, %{state | status: :paused}}
  end

  def handle_call(:pause, _from, state),
    do: {:reply, {:error, {:not_running, state.status}}, state}

  def handle_call(:resume, _from, %{status: :paused} = state) do
    {:ok, _} = Games.set_status(state.game_id, :running)
    state = %{state | status: :running}
    Persistence.broadcast_updated(state)
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
      Participants.human?(state, participant) ->
        character = Participants.world_character(state, participant)

        if character do
          {_name, pid} =
            Bootstrap.start_pc_agent(
              state.game_id,
              state.model,
              Dragonex.Models.summarizer(),
              participant,
              character,
              "auto-#{participant}"
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
          Persistence.broadcast_updated(state)
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
    if Participants.human?(state, participant) do
      case Map.get(state.pc_agents, participant) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        _ -> :ok
      end

      state = %{state | pc_agents: Map.delete(state.pc_agents, participant)}
      Persistence.broadcast_updated(state)
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  # Sincronización de level-up del héroe al world vivo. Entrada única desde el
  # LiveView de level-up; respeta el single-writer (muta el Session, persiste y
  # broadcast dentro del proceso). Mantiene el estado transitorio del combate.
  def handle_call({:sync_hero_level_up, hero_id, %Dragonex.Character{} = new_sheet}, _from, state) do
    game = Games.get_game(state.game_id)
    gc = Enum.find((game && game.characters) || [], &(&1.hero_id == hero_id))

    result =
      cond do
        is_nil(gc) ->
          {:error, :not_found}

        true ->
          # El level-up lo "propone" el propio personaje (o el current del turno si
          # lo hay). `Session.update_state/3` no exige que `actor` sea el participante
          # en turno: es solo quién origina el cambio, y un level-up no consume turno.
          actor = Session.current(state.session) || gc.name

          change = fn world ->
            {:ok, Games.merge_character_level_up(world, gc.name, new_sheet)}
          end

          case Session.update_state(state.session, actor, change) do
            {:ok, _} ->
              {:ok, _} = Games.update_character_sheet(state.game_id, hero_id, new_sheet)
              Persistence.persist(state, state.status)
              :ok

            {:error, _} = err ->
              Logger.warning(
                "dragonex game #{state.game_id}: sync_hero_level_up no aplicó al world " <>
                  "(héroe #{hero_id}): #{inspect(err)}"
              )

              err
          end
      end

    Persistence.broadcast_updated(state)
    {:reply, result, state}
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
        "dragonex game #{state.game_id} stopping: its row is gone (#{Exception.message(e)})"
      )

      {:stop, :normal, state}
  end

  # A beat Task finished successfully. Guarded on `is_reference/1` so the
  # clause only matches real Task monitor refs — otherwise it would shadow the
  # `{:retry_beat, turn_id}` tuple below (a 2-tuple carrying an atom, not a ref).
  def handle_info({ref, result}, %{busy: busy} = state) when is_reference(ref) do
    cond do
      match?(%Beat{ref: ^ref}, busy) ->
        Process.demonitor(ref, [:flush])
        {:noreply, Settlement.handle_beat_result(state, result)}

      true ->
        # Stale result from a beat no longer tracked (e.g. after a restart) — drop it.
        {:noreply, state}
    end
  end

  # A beat Task crashed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %Beat{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("dragonex game #{state.game_id} beat crashed: #{inspect(reason)}")
    {:noreply, Settlement.handle_beat_result(state, {:error, {:crashed, reason}})}
  end

  # The backoff window for a transient-provider retry elapsed — relaunch the
  # beat. While we were sleeping, `busy` was kept as a `pending_retry` marker
  # (no Task ref) so `advance/1` did NOT kick a competing beat and the turn
  # position stayed put. If the user paused during the window, re-arm the timer
  # and wait for resume rather than firing a beat under a paused loop.
  def handle_info({:retry_beat, turn_id}, %{busy: %PendingRetry{turn_id: turn_id}} = state) do
    if state.status != :running do
      Process.send_after(self(), {:retry_beat, turn_id}, 500)
      {:noreply, state}
    else
      %PendingRetry{
        participant: participant,
        instruction: instruction,
        transient_retries: tr,
        max_token_retries: mr
      } = state.busy

      world = Session.read_state(state.session)
      retries = %{transient_retries: tr, max_token_retries: mr}
      state = %{state | busy: nil, status: :running}

      state =
        if participant == "turnmaster" do
          Beats.run_turnmaster_beat(state, turn_id, world, retries)
        else
          Beats.run_beat(state, participant, instruction, turn_id, world, retries)
        end

      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The one-step advance: micro-machine actor → turnmaster (D25). Never
  # auto-chains more than one beat per tick (each completed beat schedules the
  # next). WorldDriven remains the Session policy and the fallback when the
  # TurnMaster cannot produce a valid decision.
  defp advance(%{status: status} = state) when status != :running, do: state

  defp advance(%{busy: b} = state) when b != nil, do: state

  defp advance(%{loop_phase: :turnmaster} = state) do
    world = Session.read_state(state.session)

    if Turnmaster.exploration_opener?(state, world) do
      Turnmaster.settle_exploration_opener(state)
    else
      turn_id = Beats.generate_turn_id()
      state = Beats.run_turnmaster_beat(state, turn_id, world)
      %{state | status: :running}
    end
  end

  defp advance(state) do
    case Session.current(state.session) do
      nil ->
        Persistence.persist(state, :ended)
        %{state | status: :ended}

      current ->
        # Defer the :turn marker until we KNOW we're going to act. A human who's
        # waiting for input doesn't get a marker yet — it lands when they
        # declare (their path) or when their queued intent is consumed (loop
        # path), so we never emit two markers for one turn.
        world = Session.read_state(state.session)

        cond do
          # Has an AI agent (original AI PC or auto-play enabled human)
          Participants.ai_pc?(state, current) ->
            turn_id = Beats.generate_turn_id()
            Beats.append_turn_marker(state.game_id, current, turn_id, world)

            character = Participants.world_character(state, current)

            base =
              Dragonex.PCAgent.instruction(
                current,
                character || Dragonex.Character.new(name: current),
                world
              )

            # Prompts alone couldn't stop a bot from re-declaring the same
            # non-action ("¿subimos al círculo?" x N) every turn. This compares
            # its last two narrations and, when they're near-duplicates, stitches
            # a hard anti-loop nudge onto the instruction forcing a DIFFERENT
            # concrete action this turn.
            instruction = Guardrails.with_pc_anti_loop(state.game_id, current, base)
            state = Beats.run_beat(state, current, instruction, turn_id, world)
            %{state | status: :running}

          Participants.human?(state, current) ->
            case Turnmaster.take_ready_intent(state, current, world) do
              {:ready, state} ->
                turn_id = Beats.generate_turn_id()
                Beats.append_turn_marker(state.game_id, current, turn_id, world)
                state = %{state | status: :running}
                Beats.consume_intent(state, current, turn_id, world)

              {:none, state} ->
                Persistence.persist(state, :waiting)
                Persistence.broadcast_updated(state)
                %{state | status: :waiting}
            end

          true ->
            # DM's turn (monsters/NPCs).
            turn_id = Beats.generate_turn_id()
            Beats.append_turn_marker(state.game_id, current, turn_id, world)

            # Detect stalls where the partida loops without progress:
            #   * post-combate limbo — combate ended but the timeline hasn't
            #     moved past it (PCs re-declare "¿seguimos?" forever).
            #   * exploration limbo — long stretches of pure narration with no
            #     ability check, no spawn, no scene change (the "¿empezamos con
            #     el círculo?" x 10 turns pattern). The DM gets a special
            #     instruction forcing an avance instead of "¿qué hacéis?".
            events = Games.recent_events(state.game_id, 40)

            instruction =
              cond do
                Guardrails.post_combat_limbo?(events) ->
                  Instructions.dm_post_combat_instruction()

                Guardrails.exploration_limbo?(events, world) ->
                  Logger.info(
                    "dragonex game #{state.game_id} exploration limbo — forcing DM avance"
                  )

                  Instructions.dm_advance_instruction()

                true ->
                  Instructions.dm_instruction(world.current_combatant)
              end

            # Bug #4: the DM occasionally narrates a PC acting ("*Lyra ataca al
            # goblin*"). Rule 14 forbids it but prompts alone leak through, so
            # when the DM's LAST narration matches "<pc> <action verb>", this
            # turn's instruction gets a rule-14 reminder stitched on top.
            instruction = Guardrails.with_dm_no_puppet_nudge(events, world, instruction)
            # Anti-repeat: keep DM narration varied (no "se desvanece en humo
            # sulfúrico" x N). Applied after the puppet nudge so both can stack.
            instruction = Guardrails.with_dm_anti_repeat(events, instruction)
            # Ghost combat v2: if the DM narrated a hostile appearing without
            # spawning it, force a spawn_monster this turn.
            instruction =
              Guardrails.with_dm_unspawned_hostile_nudge(events, world, instruction)

            # Language guard: DeepSeek sometimes drifts into English mid-scene.
            # If the DM's last narration reads English, force Spanish this turn.
            instruction = Guardrails.with_dm_spanish_nudge(events, instruction)

            state = Beats.run_beat(state, current, instruction, turn_id, world)
            %{state | status: :running}
        end
    end
  end

  # Off-turn declare while parked on another human: wake the TurnMaster so it
  # can honour the new intent (cut_in / give_turn_to) instead of waiting for
  # the current waiter to speak. Same intent text twice is a no-op (anti-spam).
  # If the TM fails, `fallback_world_driven` sees `tm_reeval` and parks again
  # — it must not WorldDriven-skip the waiter.
  defp maybe_reeval_turnmaster(state, declarer) do
    current = Session.current(state.session)
    sig = intents_sig(state.intents)

    cond do
      state.status != :waiting ->
        state

      state.busy != nil ->
        state

      current == declarer ->
        state

      sig == state.tm_intent_sig ->
        state

      true ->
        send(self(), @tick)

        %{
          state
          | status: :running,
            loop_phase: :turnmaster,
            tm_intent_sig: sig,
            tm_reeval: true
        }
    end
  end

  defp intents_sig(intents) when is_map(intents) do
    intents
    |> Enum.map(fn {k, v} -> {to_string(k), Intents.text(v)} end)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp intents_sig(_), do: nil
end
