defmodule Dragones.Game.Beat do
  @moduledoc """
  A live in-flight beat: the Task running the agent, plus the context the
  `Dragones.Game` process needs to settle the beat once it resolves.

  Replaces the untagged map that used to live in `state.busy` — a struct gives
  compile-time field safety (a typo'd `busy.enemies_befor` is now a compile
  error, not a silent nil) and lets the `handle_info` clauses pattern-match on
  `%Beat{}` vs `%PendingRetry{}` instead of sniffing for a `:pending_retry`
  boolean key.

  Also hosts the pure beat-retry policy (classification, backoff, narration
  text) used by `Dragones.Game`'s beat handlers — the part of the beat logic
  with no coupling to the GenServer state.
  """

  defstruct [:ref, :participant, :phase, :turn_id, :instruction, :enemies_before,
              max_token_retries: 0, transient_retries: 0]

  @type t :: %__MODULE__{
          ref: reference() | nil,
          participant: String.t(),
          phase: atom(),
          turn_id: String.t(),
          instruction: String.t(),
          enemies_before: MapSet.t(),
          max_token_retries: non_neg_integer(),
          transient_retries: non_neg_integer()
        }

  # Backoff slots for transient retries (1s, 3s, 10s, then cap). Overridable via
  # `{:dragones, :transient_backoffs}` app env so tests can shrink the windows to
  # milliseconds instead of sleeping through real seconds.
  @default_transient_backoffs [1_000, 3_000, 10_000]

  @doc "Backoff (ms) for the Nth transient retry (0-indexed), capping at the last slot."
  @spec transient_backoff(non_neg_integer()) :: non_neg_integer()
  def transient_backoff(attempt) when attempt >= 0 do
    backoffs = Application.get_env(:dragones, :transient_backoffs, @default_transient_backoffs)
    Enum.at(backoffs, attempt, List.last(backoffs))
  end

  @doc "True when the beat failed because the model hit max_tokens."
  @spec max_tokens_error?(term()) :: boolean()
  def max_tokens_error?(:max_tokens_exceeded), do: true
  def max_tokens_error?({:max_tokens_exceeded, _}), do: true
  def max_tokens_error?(_), do: false

  @doc """
  True when the beat failed because of a transient provider fault — one that
  retrying is likely to fix. DeepSeek/OpenRouter surface these as
  `{:model_request_failed, %ExAgent.RequestError{}}`. We treat as transient:
    * HTTP 5xx and 429 (overloaded / rate-limited / gateway blip)
    * transport-level :timeout and :request_failed (connection drops)
    * :provider_error bodies that read as overload/rate/unavailable
  Non-transient (4xx other than 429, missing_credentials, malformed request)
  fall straight through to the soft fallback — retrying those just wastes time.
  """
  @spec transient_provider_error?(term()) :: boolean()
  def transient_provider_error?({:model_request_failed, %ExAgent.RequestError{} = err}) do
    case err.reason do
      :timeout -> true
      :request_failed -> true
      :http_error -> err.status == 429 or (is_integer(err.status) and err.status >= 500)
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
      "⏱ INTENTA ANTERIORMENTE: tu respuesta se cortó a mitad por el límite de tokens. " <>
        "ESTA VEZ SÉ EXTREMADAMENTE BREVE: 1-2 frases de narración como mucho, " <>
        "una sola llamada a herramienta si la necesitas, y reacciona en una frase corta. " <>
        "NADA de párrafos largos, listas, ni descripciones elaboradas. Conciso y al grano.\n\n"

    brief <> (original || "Es el turno de #{actor}. Actúa en personaje.")
  end

  @doc """
  One line of in-fiction prose for a beat that failed at the engine level.
  Keeps the partida flowing instead of pausing on bot/DM hiccups.
  """
  @spec fallback_narration(String.t(), term()) :: String.t()
  def fallback_narration(actor, reason) do
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
end
