defmodule Dragonex.Game.Settlement do
  @moduledoc """
  Beat settlement: what happens when a beat Task reports back — the actor path
  (success bookkeeping, combat transitions, floor handoff to the TurnMaster)
  and the TurnMaster path (decision application or WorldDriven fallback),
  including the transient-provider retry/backoff machinery and the soft
  failure circuit breakers.

  Extracted from `Dragonex.Game`. These functions run inside the Game
  GenServer's process (single-writer, D6) and return the mutated state.
  """

  use Gettext, backend: Dragonex.Gettext
  require Logger

  alias Dragonex.Games

  alias Dragonex.Game.{
    Beat,
    Beats,
    Combat,
    Conversations,
    Participants,
    Persistence,
    PendingRetry,
    Turnmaster
  }

  alias ExAgent.Session

  # Transient provider errors (DeepSeek 503 / rate limit / connection drops /
  # timeouts) are retried with exponential backoff before falling back to the
  # soft "X titubea" narration. The provider usually recovers within seconds;
  # burning up to 3 retries (~14s total worst case) is far better UX than the
  # 5-fallback streaks a transitory outage used to produce.
  @max_transient_retries 3

  # If this many consecutive beats fall through to the soft fallback (titubea),
  # the loop PAUSES instead of feeding another round. Without this, a persistent
  # provider outage (or a wedged scene every agent keeps failing on) produces an
  # infinite "X titubea y el turno pasa de largo" stream that floods the
  # timeline and starves the server (the 503-on-pagination symptom). One full
  # round of 4 participants failing is the trigger.
  @max_fallback_streak 4

  def handle_beat_result(
        state,
        {:error, %{__struct__: ExAgent.RunError, reason: reason, partial: partial}}
      ) do
    log_token_usage(state.game_id, partial[:usage])
    handle_beat_result(state, {:error, reason})
  end

  def handle_beat_result(
        state,
        {:error, %{__struct__: ExAgent.RunError, reason: reason, partial: partial}, trace}
      ) do
    log_token_usage(state.game_id, partial[:usage])
    handle_beat_result(state, {:error, reason, trace})
  end

  def handle_beat_result(%Dragonex.Game{} = state, result) do
    %Beat{kind: kind} = state.busy

    case kind do
      :turnmaster -> handle_turnmaster_result(state, result)
      _ -> handle_actor_beat_result(state, result)
    end
  catch
    :throw, {:combat_end_commit_failed, paused} ->
      paused

    :throw, {:engine_commit_failed, _reason} ->
      # No candidate reached Session. Keep the actor's durable receipt and
      # original enemies so resume/restart can retry initiative without
      # applying its spawn/return again. This beat's Task has already finished.
      paused = %{state | busy: nil, status: :paused, loop_phase: :actor}
      Persistence.persist(paused, :paused)

      Games.append_event(state.game_id, :system, "system", "all", %{
        note:
          dgettext(
            "engine",
            "No se pudo guardar la iniciativa automática. La partida está en pausa; reanuda para volver a intentarlo."
          )
      })

      Persistence.broadcast_updated(paused)
      paused
  end

  # Actor beat (DM / PC / human): on success do NOT Session.end_turn — hand the
  # floor to the TurnMaster beat, which applies handoff (D25). Combat bookkeeping
  # still runs here so the World is honest before the TM decides.
  defp handle_actor_beat_result(state, {:ok, narration, rolls, usage, refresh}) do
    state = Dragonex.Game.SceneRefresh.commit(state, refresh)
    handle_actor_beat_result(state, {:ok, narration, rolls, usage})
  end

  defp handle_actor_beat_result(%Dragonex.Game{} = state, result) do
    %Beat{
      participant: current,
      phase: beat_phase,
      instruction: beat_instruction,
      turn_id: beat_turn_id,
      max_token_retries: beat_max_token_retries,
      transient_retries: beat_transient_retries,
      enemies_before: beat_enemies_before,
      mini_turn: mini_turn
    } = state.busy

    tool_results = state.busy.tool_results
    wait_resolution = state.busy.wait_resolution
    beat = state.busy
    state = %{state | busy: nil}

    case result do
      {:ok, _narration, rolls, usage} ->
        _ = rolls
        log_token_usage(state.game_id, usage)

        state = Combat.maybe_force_combat(state, beat_enemies_before)
        state = Combat.maybe_end_combat(state)
        state = Dragonex.Game.ToolReplay.clear(state)
        slot = Combat.main_combatant(Session.read_state(state.session))

        # Main turns mark acted_this_round; mini-turns (cut_in/react) do not.
        state =
          if mini_turn do
            state
          else
            Combat.mark_actor_acted(state, current)
          end

        unless mini_turn, do: Combat.maybe_advance_round(state, current, beat_phase)

        last =
          if is_binary(slot) and slot != "" do
            slot
          else
            current
          end

        state = %{
          state
          | fallback_streak: 0,
            last_actor: last,
            last_was_mini: mini_turn
        }

        # Mini-turn finished: clear interrupted if we just resolved it.
        state =
          if mini_turn and state.interrupted == current do
            %{state | interrupted: nil}
          else
            state
          end

        state = Conversations.finish_beat(state, current, mini_turn)

        # Exploration after a PC: the world answers (D28), or requested
        # companions speak first (D120). Skip the TM beat so
        # a mute model cannot WorldDriven-skip the DM and emit «relevo».
        {state, skipped_tm?} = Turnmaster.maybe_auto_pass_after_pc(state, current, mini_turn)

        state =
          if skipped_tm?,
            do: %{state | loop_phase: :actor},
            else: %{state | loop_phase: :turnmaster}

        # Compute AFTER maybe_auto_pass_after_pc: that path can fall back to
        # WorldDriven with a hard reason and trip the TM circuit breaker
        # (status → :paused). Using a pre-computed status would wipe the pause
        # in memory and Postgres and keep the loop ticking.
        next_status = if state.status == :paused, do: :paused, else: :running

        Persistence.persist(state, next_status)
        Persistence.broadcast_updated(state)
        if next_status == :running, do: send(self(), :advance)
        %{state | status: next_status}

      {:error, reason} ->
        cond do
          state.status == :paused and
              (Dragonex.Narration.Contract.error?(reason) or Beat.max_tokens_error?(reason)) ->
            pause_pending_narration(state, beat)

          Dragonex.Narration.Contract.error?(reason) and beat.narration_retries < 1 ->
            retries = %{
              max_token_retries: beat_max_token_retries,
              transient_retries: beat_transient_retries,
              narration_retries: beat.narration_retries + 1,
              tool_results: tool_results
            }

            instruction =
              beat_instruction <> "\n\n" <> Dragonex.Narration.Contract.feedback(reason)

            Beats.run_beat(
              %{state | status: :running},
              current,
              instruction,
              beat_turn_id,
              Session.read_state(state.session),
              retries
            )

          Dragonex.Narration.Contract.error?(reason) ->
            pause_pending_narration(state, beat)

          Beat.max_tokens_error?(reason) and beat_max_token_retries < 1 ->
            Logger.info(
              "dragonex game #{state.game_id} beat hit max_tokens for #{current}; retrying with brevity nudge"
            )

            world = Session.read_state(state.session)
            brief = Beat.brief_retry_instruction(beat_instruction, current)

            retries = %{
              max_token_retries: beat_max_token_retries + 1,
              narration_retries: beat.narration_retries,
              transient_retries: 0,
              tool_results: tool_results
            }

            Beats.run_beat(
              %{state | status: :running},
              current,
              brief,
              beat_turn_id,
              world,
              retries
            )

          Beat.max_tokens_error?(reason) ->
            pause_pending_narration(state, beat)

          Beat.transient_provider_error?(reason) and
              beat_transient_retries < @max_transient_retries ->
            schedule_transient_retry(
              state,
              current,
              beat_phase,
              beat_instruction,
              beat_turn_id,
              beat_transient_retries,
              beat_max_token_retries,
              reason,
              tool_results,
              beat.narration_retries
            )

          wait_resolution != nil and
              not Dragonex.Game.WaitResolution.resolved?(
                Session.read_state(state.session),
                wait_resolution,
                beat_turn_id
              ) ->
            paused = %{state | status: :paused, loop_phase: :actor}
            Persistence.persist(paused, :paused)

            Games.append_event(state.game_id, :system, "system", "all", %{
              note:
                dgettext(
                  "engine",
                  "No se pudo registrar la espera. La partida está en pausa; reanuda para volver a intentarlo."
                )
            })

            Persistence.broadcast_updated(paused)
            paused

          retain_failed_turns?() and not Games.turn_retained?(state.game_id, beat_turn_id) ->
            # First hard failure of this turn (D228): pause on it and keep its
            # checkpoint. Resume reruns the same turn_id; paid tools replay.
            pause_failed_turn(state, beat, reason)

          true ->
            # The same turn failed again after resume. Recover past the actor
            # without replaying committed tools, so a deterministic fault
            # cannot block the table. Combat uses its canonical slots;
            # exploration uses the policy. A spawn/return may already have
            # committed before the provider failed: settle its initiative.
            state = Combat.maybe_force_combat(state, beat_enemies_before)

            state =
              handle_non_max_token_error(
                state,
                current,
                beat_phase,
                beat_turn_id,
                mini_turn,
                reason
              )

            # Recovery already chose the next actor; avoid an empty TM hop.
            realign_after_actor_error(state, current)
        end
    end
  end

  defp pause_failed_turn(state, beat, reason) do
    Logger.warning(
      "dragonex game #{state.game_id} beat failed for #{beat.participant}; " <>
        "pausing its turn: #{inspect(reason)}"
    )

    append_failure_note(state, reason)

    note = %{
      kind: "turn_retained",
      note:
        dgettext(
          "engine",
          "El turno %{owner} no pudo completarse (%{reason}). " <>
            "La partida está en pausa; los resultados registrados se conservan. " <>
            "Reanuda para volver a intentarlo.",
          owner: turn_owner(beat.participant),
          reason: Beat.failure_label(reason)
        )
    }

    case Dragonex.Game.ToolReplay.retain_turn(state, beat, note) do
      {:ok, paused} ->
        paused

      {:error, _} ->
        paused = %{state | status: :paused, loop_phase: :actor}
        Persistence.persist(paused, :paused)
        Persistence.broadcast_updated(paused)
        paused
    end
  end

  # Tests of the skip path itself (combat slots, conversation handoff) turn
  # the first-failure pause off, as they already shrink transient backoffs.
  defp retain_failed_turns?, do: Application.get_env(:dragonex, :retain_failed_turns, true)

  defp turn_owner("dm"), do: dgettext("engine", "del DM")
  defp turn_owner(actor), do: dgettext("engine", "de %{actor}", actor: actor)

  # The raw reason is persisted and later replayed in the DM history.
  # `inspect(reason)` of a Jason.EncodeError carries the offending raw binary
  # (invalid UTF-8 bytes included), which would then wedge every future beat
  # when the history is re-serialized. Truncate to a short, sanitized digest
  # and scrub it (D7) since it re-enters the shared history as model-adjacent
  # text that could otherwise carry prompt-injection markers.
  defp append_failure_note(state, reason) do
    failure_note =
      dgettext("engine", "el turno falló: %{reason}", reason: inspect(reason))
      |> String.slice(0, 300)
      |> Dragonex.Text.sanitize_utf8()
      |> Dragonex.Text.scrub()

    {:ok, _} =
      Games.append_event(state.game_id, :system, "system", "dm", %{
        kind: "turn_failed",
        note: failure_note
      })
  end

  defp pause_pending_narration(state, beat) do
    case Dragonex.Game.ToolReplay.retain_narration(state, beat) do
      {:ok, paused} ->
        paused

      {:error, _} ->
        paused = %{state | status: :paused, loop_phase: :actor}
        Persistence.persist(paused, :paused)
        Persistence.broadcast_updated(paused)
        paused
    end
  end

  # Actor recovery already selected the next floor holder. Keep loop_phase on
  # :actor so that participant acts without an extra empty TurnMaster hop.
  defp realign_after_actor_error(state, _current) do
    %{state | loop_phase: :actor, last_actor: nil}
  end

  # TurnMaster beat: read the decision recorder and hand off, or fall back to
  # WorldDriven. Never mutates World from inside the agent — Game applies it.
  defp handle_turnmaster_result(%Dragonex.Game{} = state, result) do
    %Beat{
      turn_id: beat_turn_id,
      instruction: beat_instruction,
      max_token_retries: beat_max_token_retries,
      transient_retries: beat_transient_retries,
      phase: beat_phase
    } = state.busy

    ctx = %{
      phase: beat_phase,
      instruction: beat_instruction,
      turn_id: beat_turn_id,
      max_token_retries: beat_max_token_retries,
      transient_retries: beat_transient_retries
    }

    # Decision was stashed on busy via the beat Task return value. Failed beats
    # carry the last tool calls (PubSub evidence) for the warning; crashed
    # tasks ({:error, {:crashed, _}} from :DOWN) have none.
    {decision, result} =
      case result do
        {:ok, decision, usage} -> {decision, {:ok, usage}}
        {:error, reason, trace} when is_list(trace) -> {nil, {:error, reason, trace}}
        {:error, reason} -> {nil, {:error, reason, []}}
        other -> {nil, {:error, other, []}}
      end

    state = %{state | busy: nil}

    case result do
      {:ok, usage} ->
        log_token_usage(state.game_id, usage)
        state = Turnmaster.apply_turnmaster_decision(state, decision)
        next_status = Turnmaster.tm_next_status(state)
        state = %{state | loop_phase: :actor, tm_nudge: nil, tm_reeval: false}
        Persistence.persist(state, next_status)
        Persistence.broadcast_updated(state)
        if next_status == :running, do: send(self(), :advance)
        %{state | status: next_status}

      {:error, reason, trace} ->
        if Beat.transient_provider_error?(reason) and
             ctx.transient_retries < @max_transient_retries do
          schedule_transient_retry(
            state,
            "turnmaster",
            ctx.phase,
            ctx.instruction,
            ctx.turn_id,
            ctx.transient_retries,
            ctx.max_token_retries,
            reason
          )
        else
          Logger.warning(
            "dragonex game #{state.game_id} turnmaster beat failed: #{inspect(reason)}" <>
              tm_trace_suffix(trace)
          )

          # Provider hard faults (after transient retries exhausted) trip the
          # circuit. Model-behavior quirks (empty TestModel, exhausted script,
          # "Please respond") are soft — same as "no decision".
          reason_tag =
            if Beat.transient_provider_error?(reason), do: :tm_error, else: :no_decision

          state = Turnmaster.fallback_world_driven(state, reason_tag)
          next_status = Turnmaster.tm_next_status(state)
          state = %{state | loop_phase: :actor, tm_nudge: nil, tm_reeval: false}
          Persistence.persist(state, next_status)
          Persistence.broadcast_updated(state)
          if next_status == :running, do: send(self(), :advance)
          %{state | status: next_status}
        end
    end
  end

  # Diagnostics suffix for a failed TurnMaster beat: what the model actually
  # called in its last steps, so a looping beat can be diagnosed from the log
  # alone (the run store dies with the process). Empty when the beat produced
  # no tool calls or the evidence channel was unavailable.
  defp tm_trace_suffix([]), do: ""

  defp tm_trace_suffix(calls) do
    rendered =
      Enum.map_join(calls, "; ", fn call ->
        name = Map.get(call, :tool_name) || Map.get(call, "tool_name") || "?"
        args = Map.get(call, :args) || Map.get(call, "args") || %{}
        "#{name}(#{inspect(args)})"
      end)

    " — last calls: " <> rendered
  end

  defp handle_non_max_token_error(state, current, beat_phase, beat_turn_id, mini_turn, reason) do
    Logger.warning("dragonex game #{state.game_id} beat failed: #{inspect(reason)}")

    streak = state.fallback_streak + 1
    state = %{state | fallback_streak: streak}

    append_failure_note(state, reason)

    # Speech may already be on the timeline, and a provider failure cannot give
    # anyone an invented gesture or imply a declaration completed. Report the
    # skipped turn as a system note; committed rule results stay.
    note =
      if Participants.human?(state, current) and not Participants.ai_pc?(state, current) and
           Games.declaration_for_turn(state.game_id, current, beat_turn_id) do
        dgettext(
          "engine",
          "La declaración de %{actor} no pudo completarse. Los resultados ya registrados se conservan.",
          actor: current
        )
      else
        dgettext(
          "engine",
          "El turno %{owner} se omite tras volver a fallar. " <>
            "Los resultados ya registrados se conservan.",
          owner: turn_owner(current)
        )
      end

    {:ok, _} =
      Games.append_event(state.game_id, :system, "system", "all", %{
        turn_id: beat_turn_id,
        kind: "turn_skipped",
        note: note
      })

    # Tools may already have committed damage and spent resources before the
    # model failed. The failed main slot still counts as used, just as a
    # successful beat does. Mark it while the Session still admits its actor;
    # the next DM slot must resolve the next monster, not this one again.
    state = if mini_turn, do: state, else: Combat.mark_actor_acted(state, current)

    state = Combat.maybe_end_combat(state)
    state = Dragonex.Game.ToolReplay.clear(state)
    unless mini_turn, do: Combat.maybe_advance_round(state, current, beat_phase)
    state = Conversations.finish_beat(state, current, mini_turn)
    {state, conversation_handoff?} = Turnmaster.maybe_handoff_conversation(state, mini_turn)

    state =
      if conversation_handoff?, do: state, else: Combat.fallback_turn(state, mini: mini_turn)

    # Circuit breaker: if beats keep failing, STOP instead of feeding another
    # round. A persistent provider outage (or a wedged scene every agent keeps
    # failing on) would otherwise produce an infinite "X titubea" stream that
    # floods the timeline and starves the server. One pause + a system note lets
    # the user resume manually once the underlying issue clears.
    if streak >= @max_fallback_streak do
      Logger.warning(
        "dragonex game #{state.game_id} pausing after #{streak} consecutive fallback beats"
      )

      {:ok, _} =
        Games.append_event(state.game_id, :system, "system", "all", %{
          note:
            dgettext(
              "engine",
              "⏸ La partida se ha pausado automáticamente tras %{count} turnos fallidos seguidos. " <>
                "Reanuda manualmente cuando quieras continuar.",
              count: @max_fallback_streak
            )
        })

      Persistence.persist(state, :paused)
      Persistence.broadcast_updated(state)
      # No tick — the loop stops here until the user resumes.
      %{state | status: :paused, fallback_streak: 0}
    else
      next_status = if state.status == :paused, do: :paused, else: :running

      Persistence.persist(state, next_status)
      Persistence.broadcast_updated(state)
      if next_status == :running, do: send(self(), :advance)
      %{state | status: next_status}
    end
  end

  # Park the beat as a PendingRetry and arm a timer. While sleeping, `busy` is
  # non-nil (so `advance/1` won't fire a competing beat) but carries no Task ref
  # (so stale `{ref, _}` / `:DOWN` messages can't match it). The retry lands in
  # the Game's `handle_info({:retry_beat, turn_id})`.
  defp schedule_transient_retry(
         state,
         current,
         beat_phase,
         instruction,
         turn_id,
         transient_retries,
         max_token_retries,
         reason,
         tool_results \\ %{},
         narration_retries \\ 0
       ) do
    backoff = Beat.transient_backoff(transient_retries)

    Logger.warning(
      "dragonex game #{state.game_id} transient provider error for #{current} " <>
        "(#{inspect(reason)}); retry #{transient_retries + 1}/#{@max_transient_retries} in #{backoff}ms"
    )

    Process.send_after(self(), {:retry_beat, turn_id}, backoff)

    # A provider result can arrive after pause. Keep that pause authoritative;
    # a retry is in-flight only while the user leaves the game running. No
    # World/event write or competing advance tick is needed, just a UI update.
    state = %{
      state
      | status: if(state.status == :paused, do: :paused, else: :running),
        busy: %PendingRetry{
          participant: current,
          phase: beat_phase,
          turn_id: turn_id,
          instruction: instruction,
          model_retry: argument_retry_feedback(reason),
          tool_results: tool_results,
          transient_retries: transient_retries + 1,
          max_token_retries: max_token_retries,
          narration_retries: narration_retries
        }
    }

    Persistence.broadcast_updated(state)
    state
  end

  defp argument_retry_feedback(
         {:model_request_failed,
          %ExAgent.RequestError{provider: :req_llm, reason: :invalid_tool_arguments}}
       ),
       do: :invalid_tool_arguments

  defp argument_retry_feedback(_), do: nil

  defp log_token_usage(game_id, %{input_tokens: input} = usage) when is_integer(input) do
    cached = Dragonex.Models.cached_tokens(usage)

    if cached > 0 do
      ratio = Float.round(cached / max(input, 1) * 100, 1)
      Logger.info("dragonex game #{game_id} tokens: #{input} in (#{cached} cached, #{ratio}%)")
    end
  end

  defp log_token_usage(_game_id, _usage), do: :ok
end
