defmodule Dragonex.GameAI do
  @moduledoc """
  Which AI plays a table and who pays for it (D242), persisted in `games.ai`
  so a restart or crash rebuilds the same models:

    * `%{}` or `%{"source" => "house"}` — the server's key with its default:
      the house model in production (`Dragonex.Models.server_mode/0`), the
      env default in dev.
    * `%{"source" => "server", "provider" => "openrouter" | "opencode",
      "model" => id}` — a model the creator tried with the server keys. Only
      honoured in `:open` (dev) mode; production treats it as the house.
    * `%{"source" => "own", "provider" => id, "model" => id, "metadata" => map}`
      — the creator's own key for that provider (`Dragonex.AIProviders`).
      The key is read from their account when the table starts and never
      leaves the Game process; if it is gone, the table plays with the house.
  """

  require Logger

  alias Dragonex.{Accounts, AIProviders, Models}

  @doc "The table's choice, normalized."
  @spec selection(map()) :: map()
  def selection(%{ai: %{"source" => "own", "provider" => p, "model" => m} = ai})
      when is_binary(p) and is_binary(m),
      do: %{source: :own, provider: p, model: m, metadata: ai["metadata"]}

  def selection(%{ai: %{"source" => "server", "provider" => p, "model" => m}})
      when p in ["openrouter", "opencode"] and is_binary(m) do
    if Models.server_mode() == :open,
      do: %{source: :server, provider: p, model: m},
      else: %{source: :house}
  end

  def selection(_game), do: %{source: :house}

  @doc "The jsonb row for a selection."
  def encode(%{source: :own} = s),
    do: %{
      "source" => "own",
      "provider" => s.provider,
      "model" => s.model,
      "metadata" => s.metadata
    }

  def encode(%{source: :server} = s),
    do: %{"source" => "server", "provider" => s.provider, "model" => s.model}

  def encode(_), do: %{"source" => "house"}

  @doc """
  Models for `Dragonex.Game.Bootstrap`: `model`, `summarizer` and
  `turnmaster_model`, or `[]` to keep its defaults (env/offline Test).
  """
  @spec models(map()) :: keyword()
  def models(game), do: game |> selection() |> models_for(game.user_id)

  @doc "Build the models of a selection paid by `user_id` (`{:ok, kw}` or `{:error, reason}`)."
  def build(%{source: :own} = s, user_id) do
    with {:ok, key} <- Accounts.api_key(user_id, s.provider) do
      model = AIProviders.model(s.provider, s.model, key, s.metadata)
      {:ok, [model: model, summarizer: model, turnmaster_model: model]}
    else
      :error -> {:error, :missing_key}
    end
  rescue
    ArgumentError -> {:error, :incompatible}
  end

  def build(%{source: :server} = s, _user_id) do
    Models.prepare_selection(String.to_existing_atom(s.provider), s.model, :none)
  end

  def build(_house, _user_id) do
    if Models.server_mode() == :fixed, do: {:ok, Models.house_models()}, else: {:ok, []}
  end

  defp models_for(selection, user_id) do
    case build(selection, user_id) do
      {:ok, models} ->
        models

      {:error, reason} ->
        Logger.warning(
          "table AI #{inspect(Map.delete(selection, :metadata))} unavailable (#{inspect(reason)}); using the house model"
        )

        models_for(%{source: :house}, user_id)
    end
  end

  @doc "Short label of what plays the table, for the topbar."
  def label(game) do
    case selection(game) do
      %{source: :own} = s -> "#{AIProviders.name(s.provider)} · #{s.model}"
      %{source: :server} = s -> "#{s.provider}/#{s.model}"
      _ -> house_label()
    end
  end

  defp house_label do
    if Models.server_mode() == :fixed,
      do: Models.house_model_id(),
      else: "#{Models.provider()}/#{Models.model()}"
  end
end
