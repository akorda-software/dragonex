defmodule Dragones.Models do
  @moduledoc """
  Centralised model configuration (modelo-por-rol + cost control).

  Three concerns:

    * **DM** (`dm/0`) — the model that narrates + referees. Picked for adherence
      to the tool contract (it must propose as the right participant).
    * **Summarizer** (`summarizer/0`) — a *cheap* model used only by compaction
      to shrink old history. The "cheap role": a flash/lite model is plenty for a
      factual recap.
    * **Tuning** (`dm_max_tokens/0`) — cap output tokens per beat.

  All env-overridable so a run can swap models without code changes. Returns
  `ExAgent.Model` structs (or `%Test{}` when no API key — for tests/dev).

  ## Prompt caching

  The DM keeps a **stable prefix** (system contract + the campaign's story bible,
  baked into the instructions once) and a **volatile tail** (the per-turn world
  brief). OpenRouter auto-caches the longest stable prefix for eligible models,
  so the recurring per-turn cost drops to the tail + the single new response.
  Cached tokens are reported back via `usage.details` (see
  `cached_tokens/1`).
  """

  alias ExAgent.Models

  @doc "The DM model (narrates + referees via tools)."
  @spec dm() :: term()
  def dm do
    if System.get_env("OPENROUTER_API_KEY") do
      Models.OpenRouter.new(
        model: System.get_env("DRAGONES_MODEL", "deepseek/deepseek-v4-flash"),
        app_title: System.get_env("DRAGONES_APP_TITLE", "dragones")
      )
    else
      %Models.Test{label: "(TestModel) set OPENROUTER_API_KEY for a live DM."}
    end
  end

  @doc """
  A cheap model for compaction summaries. Defaults to a lite/flash model
  (overridable via `DRAGONES_SUMMARIZER_MODEL`). Falls back to the DM model when
  no API key is set (tests/dev).
  """
  @spec summarizer() :: term()
  def summarizer do
    if System.get_env("OPENROUTER_API_KEY") do
      Models.OpenRouter.new(
        model: System.get_env("DRAGONES_SUMMARIZER_MODEL", "google/gemini-3.1-flash-lite"),
        app_title: System.get_env("DRAGONES_APP_TITLE", "dragones")
      )
    else
      # Tests: a label TestModel so the summarize fn returns deterministic text.
      %Models.Test{label: "(recap of earlier turns)"}
    end
  end

  @doc "Max output tokens per DM beat (cost cap)."
  @spec dm_max_tokens() :: pos_integer()
  def dm_max_tokens, do: System.get_env("DRAGONES_DM_MAX_TOKENS", "1024") |> String.to_integer()

  @doc """
  Extract cached prompt tokens from a Usage map (OpenRouter/OpenAI report them
  under `prompt_tokens_details.cached_tokens`, flattened by the provider into
  `usage.details["cached_tokens"]`). Returns 0 when unknown.
  """
  @spec cached_tokens(map() | nil) :: non_neg_integer()
  def cached_tokens(nil), do: 0

  def cached_tokens(%{details: details}) when is_map(details),
    do: cached_tokens(details)

  def cached_tokens(%{"cached_tokens" => n}) when is_number(n), do: n
  def cached_tokens(_), do: 0
end
