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
  alias Dragonex.Game.{Beat, Instructions, Participants, Persistence}
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

        deps = %{
          decision: recorder,
          world: world,
          participants: names
        }

        result =
          case Server.chat(state.turnmaster, prompt, deps: deps, stream_text: false) do
            {:ok, %{usage: usage}} ->
              {:ok, Decision.get(recorder), usage}

            {:error, reason} ->
              {:error, reason}
          end

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

  defp wait_for_human?(state, participant, world) do
    world.phase == :exploration and Participants.ai_pc?(state, participant) and
      Enum.any?(state.participants, fn {n, _} ->
        n != participant and Participants.human?(state, n)
      end)
  end
end
