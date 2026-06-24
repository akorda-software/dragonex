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

  alias Dragones.{DM, Games, PCAgent}
  alias Dragones.TurnPolicy.WorldDriven
  alias ExAgent.{Server, Session}
  alias ExAgent.Session.{Participant, SharedState}

  @tick :advance

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
    roller = wrap_roller(game_id, Keyword.get(opts, :roller) || &Dragones.Dice.roll/1)

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
      # The chat timeline: recent visible events, oldest-first. Bundled here so
      # the LiveView renders purely from the snapshot (no direct Repo access).
      events: Games.recent_events(state.game_id, 50)
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
          state = consume_intent(state, participant)
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
          send(self(), @tick)
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

      {:reply, :ok, %{state | pc_agents: Map.delete(state.pc_agents, participant)}}
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
        cond do
          # Has an AI agent (original AI PC or auto-play enabled human)
          ai_pc?(state, current) ->
            character = world_character(state, current)
            instruction = PCAgent.instruction(current, character || Dragones.Character.new(name: current))
            state = run_beat(state, current, instruction)
            %{state | status: :running}

          human?(state, current) ->
            case Map.get(state.intents, current) do
              text when is_binary(text) and text != "" ->
                state = %{state | status: :running}
                consume_intent(state, current)

              _ ->
                persist(state, :waiting)
                broadcast_updated(state)
                %{state | status: :waiting}
            end

          true ->
            # DM's turn (monsters/NPCs).
            state = run_beat(state, current, dm_instruction())
            %{state | status: :running}
        end
    end
  end

  # Consume a participant's pending intent: log the action, run the beat, clear
  # the intent (durable). Used both by `declare` (live) and the loop (queued).
  defp consume_intent(state, participant) do
    text = Map.get(state.intents, participant, "")
    intents = Map.delete(state.intents, participant)
    state = %{state | intents: intents}

    {:ok, _} = Games.append_event(state.game_id, :action, participant, "all", %{text: text})
    Games.save_intents(state.game_id, intents)

    state = run_beat(state, participant, human_instruction(participant, text))
    %{state | status: :running}
  end

  defp handle_beat_result(state, result) do
    current = state.busy.participant
    state = %{state | busy: nil}

    case result do
      {:ok, narration, usage} ->
        {:ok, _} = Session.end_turn(state.session, current)
        {:ok, _} = Games.append_event(state.game_id, :narration, "dm", "all", %{text: narration})

        # Log the prompt-caching win (cached vs total input tokens) so the cost
        # saving is visible. Best-effort: a missing usage map just logs nothing.
        log_token_usage(state.game_id, usage)

        persist(state, :running)
        broadcast_updated(state)
        send(self(), @tick)
        %{state | status: :running}

      {:error, reason} ->
        Logger.warning("dragones game #{state.game_id} beat failed: #{inspect(reason)}")

        {:ok, _} =
          Games.append_event(state.game_id, :system, "system", "dm", %{
            note: "beat failed: #{inspect(reason)}"
          })

        # Stay on the same participant but pause, so a crash doesn't loop.
        persist(state, :paused)
        broadcast_updated(state)
        %{state | status: :paused}
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
  defp run_beat(%{session: session, roller: roller} = state, participant, instruction) do
    agent = agent_for(state, participant)
    world = Session.read_state(session)
    prompt = DM.turn_prompt(world, participant, instruction, "dm")
    deps = %{state: SharedState.new(session, participant), roller: roller}

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        case Server.chat(agent, prompt, deps: deps) do
          {:ok, %{output: narration, usage: usage}} -> {:ok, narration, usage}
          {:error, reason} -> {:error, reason}
        end
      end)

    %{state | busy: %{ref: task.ref, participant: participant}}
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

  defp world_character(%{session: session}, name) do
    world = Session.read_state(session)
    Map.get(world.characters, name)
  end

  defp human_instruction(name, text),
    do:
      "It is #{name}'s turn. You are proposing AS #{name}: in EVERY tool call the " <>
        "attacker/caster/who MUST be \"#{name}\" (never a monster — a monster acting now is " <>
        "REFUSED). #{name} (a player character) declares: \"#{if text == "", do: "(passes)", else: text}\". " <>
        "Resolve it by the rules (call the right tool with \"#{name}\" as the actor), then narrate."

  defp dm_instruction,
    do:
      "Act for any monsters/NPCs whose turn it is (call the tools), then narrate. " <>
        "Advance the scene."

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

  # Wrap a dice roller so every roll is published for the dice modal. The inner
  # roller is injected (tests use a fixed one); the wrapper is transparent to the
  # engine — it still returns the same value.
  defp wrap_roller(game_id, inner) do
    fn sides ->
      value = inner.(sides)

      try do
        Phoenix.PubSub.broadcast(@pubsub, topic(game_id), {:dice_roll, game_id, sides, value})
      rescue
        _ -> :ok
      end

      value
    end
  end

  # --------------------------------------------------------------- model

  defp default_model, do: Dragones.Models.dm()

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      s -> String.to_integer(s)
    end
  end
end
