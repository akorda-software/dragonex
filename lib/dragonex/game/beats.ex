defmodule Dragonex.Game.Beats do
  @moduledoc """
  Beat launching: everything that kicks an agent turn (DM, AI PC, human
  intent) or a TurnMaster beat as a supervised Task, plus the turn markers and
  intent consumption that lead into a beat.

  Extracted from `Dragonex.Game`. These functions run inside the Game
  GenServer's process and return the mutated state (single-writer, D6). The
  Task result arrives at the Game's `handle_info({ref, result})` and is
  settled by `Dragonex.Game.Settlement`.
  """

  alias Dragonex.{Brief, Games, Intents}
  alias Dragonex.Game.{Beat, Bootstrap, Instructions, Participants, Persistence}
  alias Dragonex.TurnMaster
  alias Dragonex.TurnMaster.Decision
  alias ExAgent.Server
  alias ExAgent.Session.SharedState

  def generate_turn_id do
    # 8 random hex chars — enough to be unique per turn within a partida, short
    # enough to read in a debug log.
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  def append_turn_marker(game_id, actor, turn_id, world) do
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
  def consume_intent(state, participant, turn_id, world) do
    text = Intents.text(Map.get(state.intents, participant))
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

    state =
      run_beat(
        state,
        participant,
        Instructions.human_instruction(participant, text),
        turn_id,
        world
      )

    %{state | status: :running}
  end

  # Launch one beat as `participant` in a supervised Task. The GenServer stays
  # responsive; the result arrives via handle_info({ref, result}).
  #
  # The beat context (`turn_id`, `round`, `phase`) is threaded through `deps`
  # so the `Dragonex.Events` capability can attach it to every event it
  # publishes mid-beat, and the `RollLog.on_close` callback can do the same
  # for each roll the moment it lands. Both publish live via PubSub — the chat
  # fills in as the beat unfolds, not collapsed at the end.
  def run_beat(
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
    prompt = Brief.turn_prompt(world, participant, instruction, "dm", kinds)
    shared = SharedState.new(session, participant)

    beat = %{
      game_id: game_id,
      turn_id: turn_id,
      actor: participant,
      round: world.round,
      phase: world.phase,
      pc_names: Participants.pc_names(world),
      wait_for_human: wait_for_human?(state, participant, world)
    }

    # Each finalized roll → persisted as a :dice event (with turn_id) + PubSub
    # broadcast. Captured here (in the Game's process) so the closure carries
    # `beat`, then invoked from inside the beat Task via the recorder.
    on_roll_closed = fn entry ->
      payload = Map.merge(entry, %{turn_id: turn_id, round: world.round, phase: world.phase})
      {:ok, _} = Games.append_event(game_id, :dice, participant, "all", payload)
      Persistence.broadcast_roll_group(game_id, entry)
      Persistence.broadcast_updated(game_id)
    end

    # Token-level streaming of narration: each text delta the model emits is
    # broadcast immediately so the chat renders it word-by-word as it's
    # generated, not collapsed at beat end. The `Events` capability still
    # persists the FINAL text as a :narration event when the response
    # completes — the stream is purely a UI live-preview.
    on_text_delta = fn chunk ->
      try do
        Phoenix.PubSub.broadcast(
          Dragonex.PubSub,
          Persistence.topic(game_id),
          {:text_delta, game_id, turn_id, participant, chunk}
        )
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
      |> Games.recent_events(400)
      |> Dragonex.History.from_events()

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        # Token-level streaming is great UX with a real LLM but the in-process
        # Test model can't propagate its mutated script index through a stream,
        # which would hang the loop. Stream only for real providers.
        stream? = stream_text_for(state.model)

        # One recorder per beat (linked to this Task, so it can never outlive it).
        # It is addressed by pid, so it crosses the process boundary between this
        # beat Task and ExAgent's run Task / parallel tool tasks unscathed.
        {:ok, recorder} = Dragonex.RollLog.start(on_close: on_roll_closed)
        roll_log = %Dragonex.RollLog{base: roller, recorder: recorder}

        # PCs controlados por una persona real (incluso en auto-play). La tool
        # `level_up` los excluye: un jugador humano sube siempre desde su ficha.
        human_pcs =
          for {name, %{kind: :human}} <- state.participants, into: MapSet.new(), do: name

        deps = %{
          state: shared,
          roller: roller,
          roll_log: roll_log,
          beat: beat,
          on_text_delta: on_text_delta,
          human_pcs: human_pcs
        }

        result =
          case Server.chat(agent, prompt,
                 deps: deps,
                 stream_text: stream?,
                 message_history: shared_history
               ) do
            {:ok, %{output: narration, usage: usage}} ->
              {:ok, narration, Dragonex.RollLog.entries(recorder), usage}

            {:error, reason} ->
              {:error, reason}
          end

        Dragonex.RollLog.stop(recorder)
        result
      end)

    mini = state.pending_mini == true

    %{
      state
      | pending_mini: false,
        busy: %Beat{
          ref: task.ref,
          participant: participant,
          phase: world.phase,
          turn_id: turn_id,
          instruction: instruction,
          kind: :actor,
          mini_turn: mini,
          max_token_retries: retries.max_token_retries,
          transient_retries: retries.transient_retries,
          enemies_before: Dragonex.World.living_enemies(world)
        }
    }
  end

  # Select the right agent for a turn: AI PCs have their own agent; everything
  # else (DM beats, monster turns) goes to the DM agent. TurnMaster is its own
  # server and is launched via `run_turnmaster_beat/4`, not this helper.
  defp agent_for(%{dm: dm, pc_agents: pc_agents}, name) do
    Map.get(pc_agents, name, dm)
  end

  # --------------------------------------------------------------- TurnMaster

  # The orchestration tools that record a `Decision` — the events that can end
  # a TM beat early (D79: primera decisión válida = terminal).
  @tm_decision_tools ~w(give_turn_to cut_in react pass_to_dm end_scene)

  # Grace a captured run gets to conclude on its own before we cancel it: a
  # fast (scripted/offline) run finishes in microseconds — letting it settle
  # naturally integrates its final model state and a clean history on the TM
  # server — while a live LLM looping past its decision (the playtest case)
  # blows straight through the window and gets aborted.
  @tm_capture_grace_ms 100

  def run_turnmaster_beat(
        state,
        turn_id,
        world,
        retries \\ %{max_token_retries: 0, transient_retries: 0}
      ) do
    names = state.participants |> Map.keys() |> Enum.sort()
    prompt_body = Brief.turnmaster_brief(world, state.last_actor, names, state.intents)

    instruction =
      TurnMaster.instruction(state.last_actor, world,
        participants: names,
        nudge: state.tm_nudge,
        interrupted: state.interrupted,
        pending_intents: state.intents
      )

    prompt = "WORLD:\n#{prompt_body}\n\n#{instruction}"

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        {:ok, recorder} = Decision.start()

        # Subscribe to the TM server's PubSub topic for TWO jobs: capture the
        # first valid decision tool-call (termination, D79) and keep failure
        # evidence (tool name + args per step) for beats that error out.
        topic = ExAgent.Event.agent_topic(Bootstrap.turnmaster_agent_id(state.game_id))
        _ = ExAgent.PubSub.subscribe(ExAgent.PubSub.normalize(:local), topic)

        deps = %{
          decision: recorder,
          world: world,
          participants: names
        }

        # Server.chat blocks until the run finishes, so it runs in a nested
        # task: this beat Task stays free to consume the run's PubSub events
        # and cut the run short at the FIRST valid decision instead of waiting
        # for a final-text response the prompt cannot always obtain.
        chat =
          Task.async(fn ->
            Server.chat(state.turnmaster, prompt, deps: deps, stream_text: false)
          end)

        result = watch_tm_run(chat, recorder, state.turnmaster, [])

        Decision.stop(recorder)
        result
      end)

    %{
      state
      | busy: %Beat{
          ref: task.ref,
          participant: "turnmaster",
          phase: world.phase,
          turn_id: turn_id,
          instruction: instruction,
          kind: :turnmaster,
          max_token_retries: retries.max_token_retries,
          transient_retries: retries.transient_retries,
          enemies_before: MapSet.new()
        }
    }
  end

  # Token streaming is only meaningful for real HTTP-backed providers. The
  # in-process Test model can't propagate its mutated script index back through
  # `request_stream`, so streaming it would loop on the same script item
  # forever. Anything that isn't the Test model gets the live-preview path.
  defp stream_text_for(%ExAgent.Models.Test{}), do: false
  defp stream_text_for(_), do: true

  # Watch a TurnMaster run through its PubSub events. Three exits:
  #
  #   * first valid decision tool-call finished → the decision is recorded;
  #     settle the beat with it (settle_captured_run/4),
  #   * the chat call concludes on its own → classic short path: success with
  #     whatever the recorder holds (nil = soft WorldDriven fallback) or the
  #     run error plus the accumulated tool-call trace for the warning,
  #   * the chat caller dies → treat as a crashed beat.
  #
  # The `tool_call_started` payloads are kept (most recent last, bounded) as
  # failure evidence — the loop consumes every event, so there is nothing left
  # for a post-hoc mailbox drain.
  defp watch_tm_run(%Task{} = chat, recorder, server, trace) do
    %Task{ref: chat_ref, pid: chat_pid} = chat

    receive do
      {:exagent_event,
       %ExAgent.Event{type: :tool_call_finished, payload: %{tool_name: tool, success: true}}}
      when tool in @tm_decision_tools ->
        if Decision.get(recorder) do
          settle_captured_run(chat_ref, chat_pid, recorder, server)
        else
          # A decision tool that finished without recording: invalid target,
          # combat-only tool outside combat… keep watching — the model may
          # still correct itself within its step budget.
          watch_tm_run(chat, recorder, server, trace)
        end

      {:exagent_event, %ExAgent.Event{type: :tool_call_started, payload: payload}} ->
        watch_tm_run(chat, recorder, server, [payload | trace])

      {:exagent_event, %ExAgent.Event{}} ->
        watch_tm_run(chat, recorder, server, trace)

      {^chat_ref, {:ok, %{usage: usage}}} ->
        {:ok, Decision.get(recorder), usage}

      {^chat_ref, {:error, reason}} ->
        {:error, reason, finalize_tm_trace(trace)}

      {:DOWN, _, :process, ^chat_pid, reason} ->
        {:error, {:crashed, reason}, finalize_tm_trace(trace)}
    end
  end

  # The first valid decision is terminal (D79): whatever the rest of the run
  # was going to do is waste. Give a fast run a short grace to conclude on its
  # own (natural completion integrates the mutated model — script position for
  # the offline Test model — and a clean history on the TM server); past the
  # grace, cancel the run server-side and settle with the captured decision.
  defp settle_captured_run(chat_ref, chat_pid, recorder, server) do
    decision = Decision.get(recorder)

    receive do
      {^chat_ref, {:ok, %{usage: usage}}} ->
        {:ok, decision, usage}

      {^chat_ref, _chat_error} ->
        {:ok, decision, nil}

      {:DOWN, _, :process, ^chat_pid, _reason} ->
        {:ok, decision, nil}
    after
      @tm_capture_grace_ms ->
        _ = Server.abort(server)

        receive do
          {^chat_ref, {:ok, %{usage: usage}}} ->
            {:ok, decision, usage}

          {^chat_ref, _chat_error} ->
            {:ok, decision, nil}

          {:DOWN, _, :process, ^chat_pid, _reason} ->
            {:ok, decision, nil}
        after
          # Liveness valve: the abort reply should land in milliseconds; never
          # hang the beat on a wedged server when the decision is in hand.
          5_000 -> {:ok, decision, nil}
        end
    end
  end

  # Bounded, oldest-first tool-call trace for the failure warning: only the
  # last @tm_trace_limit calls are kept.
  @tm_trace_limit 5

  defp finalize_tm_trace(trace) do
    trace |> Enum.reverse() |> Enum.take(-@tm_trace_limit)
  end

  defp wait_for_human?(state, participant, world) do
    world.phase == :exploration and Participants.ai_pc?(state, participant) and
      Enum.any?(state.participants, fn {n, _} ->
        n != participant and Participants.human?(state, n)
      end)
  end
end
