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

  alias Dragonex.Game.{
    Beat,
    Bootstrap,
    Conversations,
    Instructions,
    Participants,
    Persistence,
    Turnmaster
  }

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
    if Dragonex.Game.ToolReplay.turn_id(world, actor) == turn_id do
      :ok
    else
      {:ok, _} =
        Games.append_event(
          game_id,
          :turn,
          actor,
          "all",
          %{
            turn_id: turn_id,
            round: world.round,
            phase: world.phase,
            turn_kind: world.turn_kind,
            kind: :start
          }
          |> put_combatant(actor, world)
        )
    end
  end

  # A DM combat turn belongs to a monster or NPC; the table names it instead
  # of a generic «Turno del DM».
  defp put_combatant(payload, "dm", %{phase: :combat, current_combatant: name})
       when is_binary(name) and name != "",
       do: Map.put(payload, :combatant, name)

  defp put_combatant(payload, _actor, _world), do: payload

  # Consume a participant's pending intent: log the action, run the beat, clear
  # the intent (durable). Used both by `declare` (live) and the loop (queued).
  def consume_intent(state, participant, turn_id, world) do
    text = Intents.text(Map.get(state.intents, participant))
    intents = Map.delete(state.intents, participant)
    state = %{state | intents: intents}

    payload = %{
      text: text,
      turn_id: turn_id,
      round: world.round,
      phase: world.phase
    }

    payload =
      if world.phase == :exploration and Dragonex.Game.SceneRefresh.movement_declared?(text),
        do: Map.put(payload, :scene_before, world.scene),
        else: payload

    seconds = Dragonex.WaitDeclaration.seconds(text)

    payload =
      if seconds && world.phase == :exploration && world.conversation == nil &&
           Participants.human?(state, participant) && not Participants.ai_pc?(state, participant) &&
           not state.pending_mini do
        Map.merge(payload, %{wait_seconds: seconds, clock_before: world.elapsed_seconds})
      else
        payload
      end

    {:ok, _} =
      Games.append_event(state.game_id, :action, participant, "all", payload)

    Games.save_intents(state.game_id, intents)
    world = Conversations.register_declared_question(state, participant, text, world)

    state =
      run_beat(
        state,
        participant,
        Instructions.human_instruction(participant, text, Map.get(world, :conversation)),
        turn_id,
        world,
        %{max_token_retries: 0, transient_retries: 0},
        literal_speech: literal_human_speech(state, participant, text, world, payload)
      )

    %{state | status: :running}
  end

  # The engine already owns registered informative questions and reserved waits.
  # Publish the player's words, never confirmation of elapsed time.
  # Extra actions, interruptions and mini-turns still need the human's tools.
  defp literal_human_speech(state, participant, text, world, payload) do
    Conversations.literal_pc_speech(state, participant, text, world) ||
      Conversations.literal_npc_speech(state, participant, text, world) ||
      if Map.has_key?(payload, :wait_seconds) and world.conversation == nil and
           not state.tm_reeval and not state.last_was_mini and
           state.interrupted in [nil, ""] do
        Dragonex.WaitDeclaration.literal_speech(text)
      end
  end

  # Launch one beat as `participant` in a supervised Task. The GenServer stays
  # responsive; the result arrives via handle_info({ref, result}).
  #
  # The beat context (`turn_id`, `round`, `phase`) is threaded through `deps`
  # so the `Dragonex.Events` capability can attach it to every event it
  # publishes mid-beat, and the `RollLog.on_close` callback can do the same
  # for standalone rolls. Advertised tools buffer groups until Game saves
  # their effect or successful result. Both publish live via PubSub — the chat
  # fills in as the beat unfolds, not collapsed at the end.
  def run_beat(
        %{session: session, roller: roller, game_id: game_id} = state,
        participant,
        instruction,
        turn_id,
        world,
        retries \\ %{max_token_retries: 0, transient_retries: 0},
        opts \\ []
      ) do
    # `retries` is threaded in from handle_beat_result so a retried beat keeps
    # its retry budget honest — a max_tokens retry that then fails with a 503
    # still gets its full transient-retry budget, and a transient retry that
    # then runs long still gets one max_tokens nudge. First attempts pass the
    # default zeroed map.

    restored = Dragonex.Game.ToolReplay.restore(world, participant)
    restored = if restored && restored.turn_id == turn_id, do: restored, else: nil

    # A retry can precede the first durable tool or speech receipt. The first
    # attempt already consumed pending_mini, so retain its kind explicitly.
    mini =
      if restored,
        do: restored.mini_turn,
        else: Map.get(retries, :mini_turn, state.pending_mini == true)

    manual? =
      Participants.human?(state, participant) and not Participants.ai_pc?(state, participant)

    death_save_required =
      cond do
        restored -> restored.death_save_required
        Map.has_key?(retries, :death_save_required) -> retries.death_save_required
        true -> Dragonex.Game.DeathSaveResolution.required?(world, participant, manual?, mini)
      end

    results = Map.get(retries, :tool_results, if(restored, do: restored.tool_results, else: %{}))
    completed = if restored, do: Games.completed_narration(game_id, participant, turn_id)

    world =
      if is_nil(restored) and Map.get(world, :actor_checkpoint) != nil do
        Dragonex.Game.ToolReplay.clear(state)
        Dragonex.Game.Persistence.persist(state, state.status)
        ExAgent.Session.read_state(session)
      else
        world
      end

    game_owner = self()
    agent = agent_for(state, participant)
    # name -> :ai | :human, so the DM knows who auto-acts and who waits for input.
    kinds = state.participants |> Map.new(fn {n, p} -> {n, p.kind} end)
    events = Games.recent_events(game_id, 400)
    wait_resolution = Dragonex.Game.WaitResolution.request(participant, world, events)
    npc_memory_resolution = Dragonex.Game.NPCMemoryResolution.request(participant, world)

    inventory_resolution =
      cond do
        restored && Map.has_key?(restored, :inventory_resolution) ->
          restored.inventory_resolution

        Map.has_key?(retries, :inventory_resolution) ->
          retries.inventory_resolution

        restored && not Map.has_key?(world.actor_checkpoint || %{}, "inventory_resolution") ->
          Dragonex.Game.InventoryResolution.legacy_request(participant, world, events)

        true ->
          Dragonex.Game.InventoryResolution.request(participant, world, events)
      end

    literal = Keyword.get(opts, :literal_speech)

    # The resolver can choose tools, but a manual player's voice comes from
    # their durable action, never from the model. Re-read the exact turn on
    # retries/recovery; a nearby declaration or an autoplay beat is not a source.
    declaration =
      if Participants.human?(state, participant) and
           not Participants.ai_pc?(state, participant) and is_nil(literal),
         do: Games.declaration_for_turn(game_id, participant, turn_id)

    older_rolls =
      if is_nil(completed) and (not is_binary(literal) or literal == "") do
        case events do
          [%{seq: seq} | _] when seq > 1 -> Games.rolls_before(game_id, seq, participant)
          _ -> []
        end
      else
        []
      end

    archive = Dragonex.History.roll_archive(events, older_rolls, participant)

    prompt =
      Brief.turn_prompt(world, participant, instruction, "dm", kinds) <>
        Dragonex.Game.DeathSaveResolution.instruction(death_save_required, participant) <>
        Dragonex.Game.WaitResolution.instruction(wait_resolution, world, turn_id) <>
        if(archive == "", do: "", else: "\n\n" <> archive) <>
        Instructions.inventory_instruction(world, participant, events) <>
        Instructions.fact_instruction(world, participant) <>
        Instructions.testimony_instruction(world, participant) <>
        Dragonex.Game.NPCMemoryResolution.instruction(npc_memory_resolution) <>
        Dragonex.Game.InventoryResolution.instruction(inventory_resolution) <>
        if(kinds[participant] == :ai,
          do: Dragonex.PCAgent.response_guidance(world, participant, events),
          else: ""
        )

    shared = SharedState.new(session, participant)

    beat = %{
      game_id: game_id,
      turn_id: turn_id,
      actor: participant,
      round: world.round,
      phase: world.phase,
      death_save_required: death_save_required,
      pc_names: Participants.pc_names(world),
      character_names: Map.keys(world.characters),
      wait_resolution: wait_resolution,
      npc_memory_resolution: npc_memory_resolution,
      inventory_resolution: inventory_resolution,
      human_declaration: declaration,
      wait_for_human: wait_for_human?(state, participant, world)
    }

    # Standalone groups → persisted as a :dice event (with turn_id) + PubSub.
    # ToolReplay scopes advertised tools to deferred RollLogs; their groups
    # are saved with the World checkpoint by Persistence instead.
    # Captured here (in the Game's process) so the closure carries
    # `beat`, then invoked from inside the beat Task via the recorder.
    on_roll_closed = fn entry ->
      if Process.alive?(game_owner) do
        payload = Map.merge(entry, %{turn_id: turn_id, round: world.round, phase: world.phase})
        {:ok, _} = Games.append_event(game_id, :dice, participant, "all", payload)
        Persistence.broadcast_roll_group(game_id, entry)
        Persistence.broadcast_updated(game_id)
      end
    end

    # Reconstruct the SHARED conversation history from the partida's timeline
    # so every agent (DM + each AI PC) reads what everyone else did — not just
    # its own turns. This is the single source of cross-agent coherence: Vex
    # sees what Lyra narrated, the DM reads Vex's declared intent verbatim,
    # and the rolling dice outcomes are visible to all. Threading this through
    # as :message_history OVERRIDES the Server's per-agent accumulation, so
    # the Server becomes a stateless runner with the Game owning context.
    # AgentInstructions adds that agent's current role to the actual request
    # after compaction; exAgent does not prepend it to a nonempty history.
    shared_history = Dragonex.History.import_events(events, participant)

    table_locale = Dragonex.I18n.locale()

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        # Tasks do not inherit the table language (D236).
        Dragonex.I18n.put_locale(table_locale)
        Dragonex.Game.RunLifecycle.watch([game_owner], [self()])
        beat_owner = self()
        # Real providers may use streaming transport. Raw deltas remain
        # private; only explicit narrate and validated final_result publish.
        stream? = stream_text_for(state.model)

        # One recorder per beat (linked to this Task, so it can never outlive it).
        # It is addressed by pid, so it crosses the process boundary between this
        # beat Task and ExAgent's run Task / parallel tool tasks unscathed.
        {:ok, recorder} =
          Dragonex.RollLog.start(
            on_close: fn entry ->
              if Process.alive?(beat_owner), do: on_roll_closed.(entry)
            end
          )

        roll_log = %Dragonex.RollLog{base: roller, recorder: recorder}

        # PCs controlados por una persona real (incluso en auto-play). La tool
        # `level_up` los excluye: un jugador humano sube siempre desde su ficha.
        human_pcs =
          for {name, %{kind: :human}} <- state.participants, into: MapSet.new(), do: name

        deps = %{
          game_owner: game_owner,
          beat_owner: beat_owner,
          state: shared,
          roller: roller,
          roll_log: roll_log,
          beat: beat,
          participant_kinds: kinds,
          model_retry: Map.get(retries, :model_retry),
          on_text_delta: fn _chunk -> :ok end,
          on_tool_call_delta: Dragonex.Narration.Preview.broadcaster(beat),
          human_pcs: human_pcs,
          locale: table_locale
        }

        # A response already published before settlement failed is final.
        # Resume its bookkeeping without another model request or publication;
        # earlier speech alongside tools remains in the timeline as written.
        result =
          cond do
            completed ->
              {:ok, completed, [], nil}

            is_binary(literal) and literal != "" ->
              case Dragonex.Events.publish_completed_speech(deps, literal) do
                {:ok, speech} -> {:ok, speech, [], nil}
                {:error, reason} -> {:error, {:narration_contract, reason}}
              end

            true ->
              case Dragonex.Agent.chat(agent, prompt,
                     deps: deps,
                     stream_text: stream?,
                     message_history: shared_history
                   ) do
                {:ok, %{usage: usage} = result} ->
                  case Dragonex.Narration.Contract.publish_result(result, deps) do
                    {:ok, narration} ->
                      {:ok, narration, Dragonex.RollLog.entries(recorder), usage}

                    {:error, reason} ->
                      {:error, reason}
                  end

                {:error, reason} ->
                  {:error, reason}
              end
          end

        Dragonex.RollLog.stop(recorder)

        case result do
          {:ok, narration, rolls, usage} ->
            refresh =
              Dragonex.Game.SceneRefresh.after_beat(state, participant, game_owner,
                turn_id: turn_id,
                wait_before: world,
                wait_resolution: wait_resolution
              )

            {:ok, narration, rolls, usage, refresh}

          error ->
            error
        end
      end)

    state = %{
      state
      | pending_mini: false,
        busy: %Beat{
          ref: task.ref,
          pid: task.pid,
          participant: participant,
          phase: if(restored, do: restored.phase, else: world.phase),
          turn_id: turn_id,
          instruction: instruction,
          kind: :actor,
          mini_turn: mini,
          death_save_required: death_save_required,
          wait_resolution: wait_resolution,
          inventory_resolution: inventory_resolution,
          inventory_scene_before:
            if(restored,
              do: restored.inventory_scene_before,
              else: %{
                "pending" => world.scene_refresh_pending,
                "fingerprint" => Dragonex.Rules.Inventory.scene_fingerprint(world)
              }
            ),
          tool_results: results,
          replay_results: results,
          legacy_attack_keys: if(restored, do: restored.legacy_attack_keys, else: MapSet.new()),
          max_token_retries: retries.max_token_retries,
          transient_retries: retries.transient_retries,
          narration_retries: Map.get(retries, :narration_retries, 0),
          enemies_before:
            if(restored, do: restored.enemies_before, else: Dragonex.World.living_enemies(world))
        }
    }

    Persistence.broadcast_updated(state)
    state
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
        exploration: Turnmaster.exploration_context(state, world),
        pending_intents: state.intents
      )

    prompt = "WORLD:\n#{prompt_body}\n\n#{instruction}"
    game_owner = self()

    table_locale = Dragonex.I18n.locale()

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        # Tasks do not inherit the table language (D236).
        Dragonex.I18n.put_locale(table_locale)
        Dragonex.Game.RunLifecycle.watch([game_owner], [self()])
        {:ok, recorder} = Decision.start()

        # Subscribe to the TM server's PubSub topic for TWO jobs: capture the
        # first valid decision tool-call (termination, D79) and keep failure
        # evidence (tool name + args per step) for beats that error out.
        topic = ExAgent.Event.agent_topic(Bootstrap.turnmaster_agent_id(state.game_id))
        _ = ExAgent.PubSub.subscribe(ExAgent.PubSub.normalize(:local), topic)

        deps = %{
          game_owner: game_owner,
          beat_owner: self(),
          decision: recorder,
          world: world,
          participants: names,
          model_retry: Map.get(retries, :model_retry),
          locale: table_locale
        }

        # Server.chat blocks until the run finishes, so it runs in a nested
        # task: this beat Task stays free to consume the run's PubSub events
        # and cut the run short at the FIRST valid decision instead of waiting
        # for a final-text response the prompt cannot always obtain.
        chat =
          Task.async(fn ->
            Dragonex.I18n.put_locale(table_locale)
            # This prompt already contains the authoritative world, intents
            # and interruption context. Previous handoff prompts are obsolete
            # snapshots: accumulating them grows cost and contradicts the
            # current round/HP. Keep tool feedback only within this run.
            Dragonex.Agent.chat(state.turnmaster, prompt,
              deps: deps,
              stream_text: false,
              message_history: []
            )
          end)

        result = watch_tm_run(chat, recorder, state.turnmaster, [])

        Decision.stop(recorder)
        result
      end)

    state = %{
      state
      | busy: %Beat{
          ref: task.ref,
          pid: task.pid,
          participant: "turnmaster",
          phase: world.phase,
          turn_id: turn_id,
          instruction: instruction,
          kind: :turnmaster,
          stage: :turnmaster,
          max_token_retries: retries.max_token_retries,
          transient_retries: retries.transient_retries,
          enemies_before: MapSet.new()
        }
    }

    Persistence.broadcast_updated(state)
    state
  end

  # Token streaming is only meaningful for real HTTP-backed providers. The
  # in-process Test model can't propagate its mutated script index back through
  # `request_stream`, so streaming it would loop on the same script item
  # forever. Anything that isn't the Test model gets the live-preview path.
  defp stream_text_for(%Dragonex.GameAI.OwnKeyModel{inner: model}), do: stream_text_for(model)
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
