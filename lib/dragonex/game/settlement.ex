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

  require Logger

  alias Dragonex.Games
  alias Dragonex.Game.{Beat, Beats, Combat, Persistence, PendingRetry, Turnmaster}
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

  def handle_beat_result(%Dragonex.Game{} = state, result) do
    %Beat{kind: kind} = state.busy

    case kind do
      :turnmaster -> handle_turnmaster_result(state, result)
      _ -> handle_actor_beat_result(state, result)
    end
  end

  # Actor beat (DM / PC / human): on success do NOT Session.end_turn — hand the
  # floor to the TurnMaster beat, which applies handoff (D25). Combat bookkeeping
  # still runs here so the World is honest before the TM decides.
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

    state = %{state | busy: nil}

    case result do
      {:ok, _narration, rolls, usage} ->
        _ = rolls
        log_token_usage(state.game_id, usage)

        state = Combat.maybe_force_combat(state, beat_enemies_before)
        state = Combat.maybe_end_combat(state)

        # Main turns mark acted_this_round; mini-turns (cut_in/react) do not.
        state =
          if mini_turn do
            state
          else
            Combat.mark_actor_acted(state, current)
          end

        Combat.maybe_advance_round(state, current, beat_phase)

        state = %{
          state
          | fallback_streak: 0,
            last_actor: current,
            last_was_mini: mini_turn
        }

        # Mini-turn finished: clear interrupted if we just resolved it.
        state =
          if mini_turn and state.interrupted == current do
            %{state | interrupted: nil}
          else
            state
          end

        # Exploration after a PC: the world answers (D28). Skip the TM beat so
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
          Beat.max_tokens_error?(reason) and beat_max_token_retries < 1 ->
            Logger.info(
              "dragonex game #{state.game_id} beat hit max_tokens for #{current}; retrying with brevity nudge"
            )

            Games.delete_narrations_for_turn(state.game_id, beat_turn_id)

            world = Session.read_state(state.session)
            brief = Beat.brief_retry_instruction(beat_instruction, current)
            retries = %{max_token_retries: beat_max_token_retries + 1, transient_retries: 0}

            Beats.run_beat(
              %{state | status: :running},
              current,
              brief,
              beat_turn_id,
              world,
              retries
            )

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
              reason
            )

          true ->
            # Soft fallback used to end_turn itself. Under TurnMaster we still
            # advance past the failed actor via the TM path so the loop does not
            # dead-lock on a broken agent.
            state = handle_non_max_token_error(state, current, beat_phase, beat_turn_id, reason)
            # handle_non_max_token_error may have end_turn'd — re-align to TM.
            realign_after_actor_error(state, current)
        end
    end
  end

  # After a soft actor failure the legacy path already advanced the cursor via
  # end_turn. Keep loop_phase on :actor so the next participant acts without an
  # extra empty TM hop (the cursor already moved).
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

    # Decision was stashed on busy via the beat Task return value.
    {decision, result} =
      case result do
        {:ok, decision, usage} -> {decision, {:ok, usage}}
        other -> {nil, other}
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

      {:error, reason} ->
        cond do
          Beat.transient_provider_error?(reason) and
              beat_transient_retries < @max_transient_retries ->
            schedule_transient_retry(
              state,
              "turnmaster",
              beat_phase,
              beat_instruction,
              beat_turn_id,
              beat_transient_retries,
              beat_max_token_retries,
              reason
            )

          true ->
            Logger.warning(
              "dragonex game #{state.game_id} turnmaster beat failed: #{inspect(reason)}"
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

  defp handle_non_max_token_error(state, current, beat_phase, beat_turn_id, reason) do
    Logger.warning("dragonex game #{state.game_id} beat failed: #{inspect(reason)}")

    streak = state.fallback_streak + 1
    state = %{state | fallback_streak: streak}

    # The failure note is persisted and later replayed in the shared history.
    # `inspect(reason)` of a Jason.EncodeError carries the offending raw binary
    # (invalid UTF-8 bytes included), which would then wedge every future beat
    # when the history is re-serialized. Truncate to a short, sanitized digest
    # and scrub it (D7) since it re-enters the shared history as model-adjacent
    # text that could otherwise carry prompt-injection markers.
    failure_note =
      ("el turno falló: " <> inspect(reason))
      |> String.slice(0, 300)
      |> Dragonex.Text.sanitize_utf8()
      |> Dragonex.Text.scrub()

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
      fallback = Beat.fallback_narration(current, reason)
      {:ok, _} = Games.append_event(state.game_id, :narration, current, "all", %{text: fallback})
    end

    {:ok, _} = Session.end_turn(state.session, current)

    state = Combat.maybe_end_combat(state)
    Combat.maybe_advance_round(state, current, beat_phase)

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
            "⏸ La partida se ha pausado automáticamente tras #{@max_fallback_streak} turnos fallidos seguidos. " <>
              "Reanuda manualmente cuando quieras continuar."
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
         reason
       ) do
    backoff = Beat.transient_backoff(transient_retries)

    Logger.warning(
      "dragonex game #{state.game_id} transient provider error for #{current} " <>
        "(#{inspect(reason)}); retry #{transient_retries + 1}/#{@max_transient_retries} in #{backoff}ms"
    )

    Process.send_after(self(), {:retry_beat, turn_id}, backoff)

    # Keep status as :running (a retry is mid-flight), but do NOT persist/tick —
    # the world hasn't changed and we don't want advance() to fire. busy stays
    # populated so the loop stays parked until the retry resolves.
    %{
      state
      | status: :running,
        busy: %PendingRetry{
          participant: current,
          phase: beat_phase,
          turn_id: turn_id,
          instruction: instruction,
          transient_retries: transient_retries + 1,
          max_token_retries: max_token_retries
        }
    }
  end

  defp log_token_usage(game_id, %{input_tokens: input} = usage) when is_integer(input) do
    cached = Dragonex.Models.cached_tokens(usage)

    if cached > 0 do
      ratio = Float.round(cached / max(input, 1) * 100, 1)
      Logger.info("dragonex game #{game_id} tokens: #{input} in (#{cached} cached, #{ratio}%)")
    end
  end

  defp log_token_usage(_game_id, _usage), do: :ok
end
