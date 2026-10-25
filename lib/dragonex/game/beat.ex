defmodule Dragonex.Game.Beat do
  @moduledoc """
  A live in-flight beat: the Task running the agent, plus the context the
  `Dragonex.Game` process needs to settle the beat once it resolves.

  Replaces the untagged map that used to live in `state.busy` — a struct gives
  compile-time field safety (a typo'd `busy.enemies_befor` is now a compile
  error, not a silent nil) and lets the `handle_info` clauses pattern-match on
  `%Beat{}` vs `%PendingRetry{}` instead of sniffing for a `:pending_retry`
  boolean key.

  Also hosts the pure beat-retry policy (classification, backoff, narration
  text) used by `Dragonex.Game`'s beat handlers — the part of the beat logic
  with no coupling to the GenServer state.
  """
  use Gettext, backend: Dragonex.Gettext

  defstruct [
    :ref,
    :pid,
    :participant,
    :phase,
    :turn_id,
    :instruction,
    :enemies_before,
    # :actor (DM/PC beat) | :turnmaster (handoff decision beat, D25)
    kind: :actor,
    stage: :acting,
    # Whether this actor beat is a mini-turn (cut_in/react) — does not mark
    # acted_this_round when it settles.
    mini_turn: false,
    death_save_required: false,
    wait_resolution: nil,
    inventory_scene_before: nil,
    tool_results: %{},
    tool_commits: %{},
    replay_results: %{},
    legacy_attack_keys: MapSet.new(),
    replay_counts: %{},
    max_token_retries: 0,
    transient_retries: 0,
    narration_retries: 0
  ]

  @type t :: %__MODULE__{
          ref: reference() | nil,
          pid: pid() | nil,
          participant: String.t(),
          phase: atom(),
          turn_id: String.t(),
          instruction: String.t(),
          enemies_before: MapSet.t(),
          kind: :actor | :turnmaster,
          stage: :acting | :scene_review | :turnmaster,
          mini_turn: boolean(),
          death_save_required: boolean(),
          max_token_retries: non_neg_integer(),
          transient_retries: non_neg_integer(),
          narration_retries: non_neg_integer()
        }

  # Backoff slots for transient retries (1s, 3s, 10s, then cap). Overridable via
  # `{:dragonex, :transient_backoffs}` app env so tests can shrink the windows to
  # milliseconds instead of sleeping through real seconds.
  @default_transient_backoffs [1_000, 3_000, 10_000]

  @doc "Backoff (ms) for the Nth transient retry (0-indexed), capping at the last slot."
  @spec transient_backoff(non_neg_integer()) :: non_neg_integer()
  def transient_backoff(attempt) when attempt >= 0 do
    backoffs = Application.get_env(:dragonex, :transient_backoffs, @default_transient_backoffs)
    Enum.at(backoffs, attempt, List.last(backoffs))
  end

  @doc "True when the beat failed because the model hit max_tokens."
  @spec max_tokens_error?(term()) :: boolean()
  def max_tokens_error?(:max_tokens_exceeded), do: true
  def max_tokens_error?({:max_tokens_exceeded, _}), do: true

  def max_tokens_error?(
        {:model_request_failed, %ExAgent.RequestError{reason: {:incomplete_response, :length}}}
      ),
      do: true

  def max_tokens_error?(_), do: false

  @doc """
  True when the beat failed because of a transient provider fault — one that
  retrying is likely to fix. DeepSeek/OpenRouter surface these as
  `{:model_request_failed, %ExAgent.RequestError{}}`. We treat as transient:
    * HTTP 5xx and 429 (overloaded / rate-limited / gateway blip)
    * transport-level :timeout and :request_failed (connection drops)
    * :provider_error bodies that read as overload/rate/unavailable
    * invalid generated tool arguments rejected by the v2 ReqLLM envelope
      (bounded retry keeps strict validation and replays confirmed effects)
  Non-transient (4xx other than 429, missing_credentials, malformed request)
  pause the turn without retrying (D228) — retrying those just wastes time.
  """
  @spec transient_provider_error?(term()) :: boolean()
  def transient_provider_error?({:model_request_failed, %ExAgent.RequestError{} = err}) do
    case err.reason do
      :timeout -> true
      {:timeout, :total} -> true
      {:timeout, :receive} -> true
      :request_failed -> true
      :invalid_tool_arguments -> err.provider == :req_llm
      :http_error -> err.status == 429 or (is_integer(err.status) and err.status >= 500)
      :model_request_failed -> err.status == 429 or (is_integer(err.status) and err.status >= 500)
      :provider_error -> transient_body?(err.body)
      _ -> false
    end
  end

  # A crashed Task is not a provider fault; don't retry it.
  def transient_provider_error?({:crashed, _}), do: false
  def transient_provider_error?(_), do: false

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

  @doc """
  Brevity nudge for a max_tokens retry. Prepends a hard "keep it tight"
  instruction to whatever the original beat instruction was, so the model lands
  a complete response inside max_tokens on the second shot.
  """
  @spec brief_retry_instruction(String.t() | nil, String.t()) :: String.t()
  def brief_retry_instruction(original, actor) do
    brief =
      dgettext(
        "prompts",
        "⏱ INTENTA ANTERIORMENTE: tu respuesta se cortó a mitad por el límite de tokens. " <>
          "ESTA VEZ SÉ EXTREMADAMENTE BREVE: 1-2 frases de narración como mucho, " <>
          "una sola llamada a herramienta si la necesitas, y reacciona en una frase corta. " <>
          "NADA de párrafos largos, listas, ni descripciones elaboradas. Conciso y al grano."
      ) <> "\n\n"

    brief <>
      (original ||
         dgettext("prompts", "Es el turno de %{actor}. Actúa en personaje.", actor: actor))
  end

  @doc """
  Short public reason for a failed actor turn (D228). The raw reason stays in
  the DM-only failure note; players get a cause they can act on, never prose
  that pretends the scene moved on.
  """
  @spec failure_label(term()) :: String.t()
  def failure_label({:retention_limit_exceeded, _}),
    do: dgettext("engine", "la respuesta del modelo superó el tamaño permitido")

  def failure_label({:unexpected_model_behavior, _}),
    do: dgettext("engine", "el modelo no devolvió una respuesta válida")

  def failure_label({:crashed, _}), do: dgettext("engine", "error interno del motor")

  def failure_label({:model_request_failed, %ExAgent.RequestError{} = err} = reason) do
    cond do
      transient_provider_error?(reason) ->
        dgettext("engine", "el proveedor no respondió tras varios intentos")

      is_integer(err.status) and err.status in 400..499 ->
        dgettext("engine", "el proveedor rechazó la petición")

      true ->
        dgettext("engine", "falló la petición al proveedor")
    end
  end

  def failure_label(_), do: dgettext("engine", "error inesperado")
end
