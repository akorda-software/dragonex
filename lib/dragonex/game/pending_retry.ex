defmodule Dragonex.Game.PendingRetry do
  @moduledoc """
  A parked beat waiting for its transient-retry backoff window to elapse.

  While sleeping, `state.busy` holds one of these (instead of a `%Game.Beat{}`)
  so `advance/1` won't fire a competing beat and the turn position stays put —
  but there's no Task `ref`, so stale `{ref, _}` / `:DOWN` messages can't match
  it. The retry lands in `handle_info({:retry_beat, turn_id})`.
  """

  defstruct [
    :participant,
    :phase,
    :turn_id,
    :instruction,
    :model_retry,
    tool_results: %{},
    max_token_retries: 0,
    transient_retries: 0,
    narration_retries: 0
  ]

  @type t :: %__MODULE__{
          participant: String.t(),
          phase: atom(),
          turn_id: String.t(),
          instruction: String.t(),
          model_retry: nil | :invalid_tool_arguments,
          max_token_retries: non_neg_integer(),
          transient_retries: non_neg_integer(),
          narration_retries: non_neg_integer()
        }
end
