defmodule Dragonex.AIProviders do
  @moduledoc """
  Providers a player can pay for with their own key (D242).

  exAgent 2.1 only runs tools over OpenAI Chat, so every provider is reached
  through its OpenAI-compatible endpoint: OpenRouter with its own profile
  (catalogue metadata, routing), the rest with the generic Chat profile and
  reasoning left undeclared. Listing models is free and doubles as the key
  check; `probe/1` makes one tiny real request through the same adapter the
  table uses, so a model that exposes its reasoning or rejects the profile
  fails here and not on the first turn.

  HTTP options can be extended with `config :dragonex, :ai_http` (tests plug
  `Req.Test` there). `config :dragonex, :ai_probe` may replace the probe.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Models

  @providers [
    %{
      id: "openrouter",
      name: "OpenRouter",
      base_url: "https://openrouter.ai/api/v1",
      keys_url: "https://openrouter.ai/settings/keys"
    },
    %{
      id: "opencode",
      name: "OpenCode Go",
      base_url: "https://opencode.ai/zen/go/v1",
      keys_url: "https://opencode.ai/auth"
    },
    %{
      id: "openai",
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      keys_url: "https://platform.openai.com/api-keys"
    },
    %{
      id: "google",
      name: "Google Gemini",
      base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
      keys_url: "https://aistudio.google.com/apikey"
    },
    %{
      id: "anthropic",
      name: "Anthropic",
      base_url: "https://api.anthropic.com/v1",
      keys_url: "https://console.anthropic.com/settings/keys"
    }
  ]

  @ids Enum.map(@providers, & &1.id)

  # Generic Chat models: tools assumed, reasoning not requested.
  @plain_metadata %{"supported_parameters" => ["tools"]}

  @doc "Every provider a player can add, in display order."
  def all, do: @providers

  @doc "Provider ids (`\"openrouter\"`, `\"anthropic\"`, …)."
  def ids, do: @ids

  @doc "The provider row, or nil."
  def get(id), do: Enum.find(@providers, &(&1.id == id))

  @doc "Display name of a provider id."
  def name(id), do: (get(id) || %{name: id}).name

  @doc """
  The models this key can run with tools, as `%{id, metadata}`. A rejected key
  answers `{:error, :unauthorized}`.
  """
  @spec list_models(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_models(provider, api_key) when provider in @ids and is_binary(api_key) do
    with :ok <- check_key(provider, api_key),
         {:ok, body} <- get_json(provider, "/models" <> list_query(provider), api_key) do
      models =
        (body["data"] || [])
        |> Enum.flat_map(&to_model(provider, &1))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&String.downcase(&1.id))

      {:ok, models}
    end
  end

  def list_models(_provider, _api_key), do: {:error, :unknown_provider}

  @doc """
  The table's model for this provider and key. Raises `ArgumentError` when the
  profile cannot be built (e.g. an OpenRouter model whose reasoning cannot be
  switched off).
  """
  def model(provider, id, api_key, metadata) when provider in @ids do
    if provider == "openrouter",
      do: Models.chat_model(:openrouter, id, api_key, metadata, routing: %{}),
      else:
        Models.chat_model(:openai_compatible, id, api_key, metadata || @plain_metadata,
          base_url: get(provider).base_url
        )
  end

  @doc "One tiny real request through the table's adapter: `:ok` or `{:error, reason}`."
  def probe(model) do
    case Application.get_env(:dragonex, :ai_probe) do
      fun when is_function(fun, 1) -> fun.(model)
      _ -> live_probe(model)
    end
  end

  defp live_probe(model) do
    agent = ExAgent.new(model: model, instructions: "Answer with the single word OK.")

    case ExAgent.run(agent, "OK?", model_settings: [max_tokens: 256]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc "A short, user-facing reason for a failed listing or probe."
  def error_message({:error, :unauthorized}),
    do: dgettext("ui", "El proveedor no acepta esta clave.")

  def error_message({:error, {:http, status}}),
    do: dgettext("ui", "El proveedor respondió con un error (%{status}).", status: status)

  def error_message({:error, {:network, _}}),
    do: dgettext("ui", "No se pudo contactar con el proveedor. Inténtalo de nuevo.")

  def error_message(_),
    do:
      dgettext(
        "ui",
        "Este modelo no funciona con la mesa (herramientas o razonamiento). Elige otro."
      )

  # ------------------------------------------------------------------ HTTP

  # OpenRouter lists models without auth, so the key is checked on its own.
  defp check_key("openrouter", api_key) do
    case get_json("openrouter", "/key", api_key) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp check_key(_provider, _api_key), do: :ok

  defp list_query("anthropic"), do: "?limit=1000"
  defp list_query(_), do: ""

  defp get_json(provider, path, api_key) do
    options =
      [
        url: get(provider).base_url <> path,
        headers: headers(provider, api_key),
        receive_timeout: 20_000,
        retry: false
      ] ++ Application.get_env(:dragonex, :ai_http, [])

    case Req.get(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp headers("anthropic", api_key),
    do: [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}]

  defp headers(_provider, api_key), do: [{"authorization", "Bearer " <> api_key}]

  # --------------------------------------------------------------- catalogue

  defp to_model("openrouter", %{"id" => id} = m) do
    metadata = Map.take(m, ["supported_parameters", "reasoning"])
    if Models.chat_compatible?(metadata), do: [%{id: id, metadata: metadata}], else: []
  end

  defp to_model("google", %{"id" => "models/" <> id}), do: to_model("google", %{"id" => id})

  defp to_model("google", %{"id" => id}) do
    if String.starts_with?(id, "gemini") and
         not String.contains?(id, ~w(embedding tts image live audio aqa)),
       do: [%{id: id, metadata: @plain_metadata}],
       else: []
  end

  defp to_model("openai", %{"id" => id}) do
    chat? = String.starts_with?(id, ~w(gpt- chatgpt- o1 o3 o4))

    other? =
      String.contains?(
        id,
        ~w(embedding tts whisper dall-e image audio realtime transcribe moderation search instruct)
      )

    if chat? and not other?, do: [%{id: id, metadata: @plain_metadata}], else: []
  end

  defp to_model(_provider, %{"id" => id}) when is_binary(id),
    do: [%{id: id, metadata: @plain_metadata}]

  defp to_model(_provider, _), do: []
end
