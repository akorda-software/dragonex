defmodule Dragonex.Models do
  @moduledoc """
  Centralised model configuration (provider selector + modelo-por-rol + cost control).

  Four concerns:

    * **Provider** (`provider/0`) — which gateway serves the models. Two are
      wired up, swappable without code changes via `DRAGONEX_PROVIDER`:

        * `openrouter` — [OpenRouter](https://openrouter.ai) (pay-per-token).
          Env key: `OPENROUTER_API_KEY`. Model slugs are namespaced, e.g.
          `deepseek/deepseek-v4-flash`.
        * `opencode` — [OpenCode Zen/Go](https://opencode.ai/docs/zen) gateway,
          an OpenAI-compatible endpoint. Env key: `OPENCODE_API_KEY`. Model ids
          are bare Zen slugs, e.g. `deepseek-v4-flash`. The flat-rate **OpenCode
          Go** ($10/mo) and pay-as-you-go **Zen** plans share model ids/auth but
          use distinct base URLs; the plan is picked inside the adapter
          (`OPENCODE_PLAN`, default `go`), resolved by `base_url/1`.

    * **DM** (`dm/0`) — the model that narrates + referees. Picked for adherence
      to the tool contract (it must propose as the right participant).
    * **Summarizer** (`summarizer/0`) — a *cheap* model used only by compaction
      to shrink old history. The "cheap role": a flash/lite model is plenty for a
      factual recap.
    * **Tuning** (`dm_max_tokens/0`) — cap output tokens per beat.

  All env-overridable so a run can swap providers/models without code changes.
  Returns `ExAgent.Models.ReqLLM` profiles (or `%Test{}` when no API key — for
  tests/dev).

  > **Attribution:** `DRAGONEX_APP_TITLE` (default `"dragonex"`) is the canonical
  > knob for provider attribution (OpenRouter `X-Title` header). OpenCode ignores
  > it; OpenRouter honours it.

  ## Prompt caching

  The DM keeps a **stable prefix** (system contract + the campaign's story bible,
  baked into the instructions once) and a **volatile tail** (the per-turn world
  brief). Both providers auto-cache the longest stable prefix for eligible
  models, so the recurring per-turn cost drops to the tail + the single new
  response. Cached tokens are reported back via `usage.details` (see
  `cached_tokens/1`).
  """

  use Gettext, backend: Dragonex.Gettext

  require Logger

  alias ExAgent.Models

  # Provider catalogue — the single source of truth for the wiring. Each row
  # pairs the env var holding the provider's API key with the per-role default
  # model ids. Adding a provider = one row here + one arm in
  # `provider/0`; the dispatch below is generic.
  @providers %{
    openrouter: %{
      api_key_env: "OPENROUTER_API_KEY",
      dm: "deepseek/deepseek-v4-flash",
      summarizer: "google/gemini-3.1-flash-lite",
      # Cheap/fast orchestrator: one tool-call per beat (D25 TurnMaster).
      turnmaster: "deepseek/deepseek-v4-flash"
    },
    opencode: %{
      api_key_env: "OPENCODE_API_KEY",
      dm: "deepseek-v4-flash",
      summarizer: "gemini-3.5-flash-lite",
      turnmaster: "deepseek-v4-flash"
    }
  }

  @doc "True para perfiles de proveedor real; `%Test{}` y demás valores no lo son."
  def live?(%Models.ReqLLM{}), do: true
  def live?(_), do: false

  @doc "Settings admitidos por el modelo efectivo; Test conserva los extras offline."
  def request_settings(%Models.ReqLLM{} = model, settings, _extra) do
    if model.reasoning_mode == :none, do: Keyword.delete(settings, :temperature), else: settings
  end

  def request_settings(_model, settings, extra) when is_map(extra) and map_size(extra) > 0,
    do: Keyword.put(settings, :extra, extra)

  def request_settings(_model, settings, _extra), do: settings

  @doc """
  True when the catalogue confirms tools and a way to run without reasoning:
  the only profiles exAgent 2.1 admits (`chat_model/5`).
  """
  def chat_compatible?(metadata) when is_map(metadata) do
    "tools" in (metadata["supported_parameters"] || []) and reasoning_profile(metadata) != nil
  end

  def chat_compatible?(_), do: false

  defp reasoning_profile(metadata) do
    parameters = metadata["supported_parameters"] || []
    reasoning = metadata["reasoning"]

    cond do
      is_map(reasoning) and reasoning["mandatory"] == false and
          "reasoning_effort" in parameters ->
        {%{
           enabled: true,
           effort: %{supported: true, values: ["none"]},
           thinking: %{disable_supported: true}
         }, :none}

      is_nil(reasoning) and
          not Enum.any?(parameters, &(&1 in ["reasoning", "reasoning_effort"])) ->
        {%{enabled: false}, nil}

      true ->
        nil
    end
  end

  @doc """
  Construye un perfil Chat explícito desde metadatos públicos, sin IO.
  `opts[:base_url]` apunta a otro endpoint compatible (claves de jugador, D242)
  y `opts[:routing]` sustituye el routing de OpenRouter de `routing_for/1`.
  """
  def chat_model(provider, id, api_key, metadata, opts \\ []) do
    parameters = metadata["supported_parameters"] || []

    unless "tools" in parameters,
      do: raise(ArgumentError, "El catálogo no confirma herramientas para #{id}.")

    {reasoning_caps, mode} =
      reasoning_profile(metadata) ||
        raise ArgumentError,
              "El catálogo no confirma que se pueda desactivar el razonamiento de #{id}."

    Models.ReqLLM.new(
      model: %{
        provider: if(provider == :openrouter, do: :openrouter, else: :openai),
        id: id,
        capabilities: %{tools: %{enabled: true}, reasoning: reasoning_caps},
        extra: %{wire: %{protocol: "openai_chat"}}
      },
      api_key: api_key,
      base_url: Keyword.get_lazy(opts, :base_url, fn -> base_url(provider) end),
      tool_profile:
        if(provider == :openrouter, do: :openrouter_chat_tools_v1, else: :chat_tools_v1),
      provider_options:
        if(provider == :openrouter,
          do: [
            openrouter_provider: Keyword.get_lazy(opts, :routing, fn -> routing_for(id) end),
            app_title: System.get_env("DRAGONEX_APP_TITLE", "dragonex")
          ],
          else: []
        ),
      reasoning_mode: mode,
      total_timeout: Keyword.get(opts, :total_timeout, 60_000)
    )
  end

  @doc """
  Routing vinculante por modelo para las pruebas solicitadas por el usuario.
  DeepSeek queda fijado a Decart salvo que `DRAGONEX_DEEPSEEK_PROVIDERS`
  (CSV de slugs) indique otros: sigue siendo estricto, sin alternativas.
  Decart entrega los argumentos de las tools de una vez; los proveedores que
  los trocean permiten ver la narración mientras se genera (R16).
  """
  def routing_for("deepseek/deepseek-v4.1-flash") do
    providers =
      case parse_provider_order(System.get_env("DRAGONEX_DEEPSEEK_PROVIDERS")) do
        [] -> ["decart"]
        list -> list
      end

    %{order: providers, only: providers, allow_fallbacks: false, require_parameters: true}
  end

  def routing_for("xiaomi/mimo-v2.6-flash"),
    do: %{order: ["io-net"], only: ["io-net"], allow_fallbacks: false, require_parameters: true}

  # ReqLLM valida `openrouter_provider` como mapa de claves atom; el fragmento
  # de `openrouter_provider_extra/0` lleva claves string para el cuerpo JSON.
  def routing_for(_id) do
    case openrouter_provider_extra() do
      %{"provider" => %{"order" => order, "allow_fallbacks" => fallbacks}} ->
        %{order: order, allow_fallbacks: fallbacks}

      _ ->
        %{}
    end
  end

  @doc """
  The server's default provider for new tables in dev (`:open` mode):
  `DRAGONEX_PROVIDER` (default `openrouter`). Returns `:openrouter` or
  `:opencode`; an unknown value falls back to `:openrouter` (logged as a
  warning) so a typo never silently breaks the app. Each table keeps its own
  choice in `games.ai` (D242).
  """
  @spec provider() :: :openrouter | :opencode
  def provider, do: env_provider()

  @doc "The provider resolved purely from `DRAGONEX_PROVIDER` (ignores override)."
  @spec env_provider() :: :openrouter | :opencode
  def env_provider do
    case System.get_env("DRAGONEX_PROVIDER", "openrouter") do
      "opencode" ->
        :opencode

      "openrouter" ->
        :openrouter

      other ->
        Logger.warning("unknown DRAGONEX_PROVIDER=#{inspect(other)}, falling back to openrouter")
        :openrouter
    end
  end

  @doc "The default DM model slug: `DRAGONEX_MODEL` → the provider's catalogue default."
  @spec model() :: String.t()
  def model, do: blank_to_nil(System.get_env("DRAGONEX_MODEL")) || @providers[provider()].dm

  # ---------------------------------------------------------------------------
  # Server-paid tables (D242)
  # ---------------------------------------------------------------------------

  @house_model "deepseek/deepseek-v4.1-flash"

  # Share of tokens per request in our tables: long prompts, mostly cached,
  # short narration. Ranks providers by what a turn really costs, not by the
  # prompt price alone (OpenRouter's `:floor` picked the priciest output).
  @house_weights %{cached: 0.77, prompt: 0.19, completion: 0.04}
  @house_fallback_order ["morph", "decart", "relace", "deepseek"]
  @house_routing_ttl :timer.hours(6)

  # Catalogue values for the house model, used when the catalogue is unreachable.
  @house_metadata %{
    "supported_parameters" => ["tools", "reasoning", "reasoning_effort"],
    "reasoning" => %{"mandatory" => false}
  }

  @doc """
  How tables paid with the server key choose their model:

    * `:fixed` (production) — only `#{@house_model}`, on the cheapest
      providers for our usage. Choosing a model needs the player's own key.
    * `:open` (dev) — the creator picks any OpenRouter/OpenCode model with
      the server keys, to try them out.

  `DRAGONEX_SERVER_MODELS=open|fixed` overrides `config :dragonex, :server_models`.
  """
  @spec server_mode() :: :fixed | :open
  def server_mode do
    case System.get_env("DRAGONEX_SERVER_MODELS") do
      "open" -> :open
      "fixed" -> :fixed
      _ -> Application.get_env(:dragonex, :server_models, :fixed)
    end
  end

  @doc "The only model the server pays for in production."
  def house_model_id, do: @house_model

  @doc """
  The house model for every role (DM, summarizer, TurnMaster), or `[]` without
  a server key so the table falls back to the offline Test models.
  """
  @spec house_models() :: keyword()
  def house_models do
    case blank_to_nil(System.get_env("OPENROUTER_API_KEY")) do
      nil ->
        []

      key ->
        metadata =
          try do
            catalogue_metadata!(:openrouter, @house_model)
          rescue
            ArgumentError -> @house_metadata
          end

        model =
          chat_model(:openrouter, @house_model, key, metadata, routing: house_routing())

        [model: model, summarizer: model, turnmaster_model: model]
    end
  end

  @doc """
  OpenRouter routing for the house model: providers that run tools, cheapest
  first for our token mix, refreshed every few hours. Falls back to a known
  cheap order when OpenRouter cannot be reached.
  """
  def house_routing do
    order =
      case :persistent_term.get({__MODULE__, :house_routing}, nil) do
        {at, order} when is_list(order) ->
          if System.monotonic_time(:millisecond) - at < @house_routing_ttl,
            do: order,
            else: fetch_house_order()

        _ ->
          fetch_house_order()
      end

    %{order: order, allow_fallbacks: true, require_parameters: true}
  end

  defp fetch_house_order do
    url = "#{base_url(:openrouter)}/models/#{@house_model}/endpoints"

    order =
      case Req.get(url, [receive_timeout: 5_000, retry: false] ++ ai_http()) do
        {:ok, %{status: 200, body: %{"data" => %{"endpoints" => endpoints}}}} ->
          rank_endpoints(endpoints)

        _ ->
          []
      end

    order = if order == [], do: @house_fallback_order, else: order

    :persistent_term.put(
      {__MODULE__, :house_routing},
      {System.monotonic_time(:millisecond), order}
    )

    order
  rescue
    _ -> @house_fallback_order
  end

  @doc """
  Provider slugs of OpenRouter endpoints that run tools, cheapest first for
  `@house_weights` (a provider without cache pricing pays the prompt price
  for cached tokens). At most 32, as OpenRouter routing allows.
  """
  @spec rank_endpoints([map()]) :: [String.t()]
  def rank_endpoints(endpoints) when is_list(endpoints) do
    endpoints
    |> Enum.filter(&("tools" in (&1["supported_parameters"] || [])))
    |> Enum.filter(&((&1["status"] || 0) >= 0))
    |> Enum.flat_map(fn e ->
      slug = e["tag"] || (e["provider_name"] && String.downcase(e["provider_name"]))

      with true <- is_binary(slug) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.\/-]*\z/, slug),
           {:ok, prompt} <- price(e, "prompt"),
           {:ok, completion} <- price(e, "completion") do
        cached =
          case price(e, "input_cache_read") do
            {:ok, p} -> p
            :error -> prompt
          end

        cost =
          @house_weights.cached * cached + @house_weights.prompt * prompt +
            @house_weights.completion * completion

        [{cost, slug}]
      else
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.take(32)
  end

  defp price(endpoint, key) do
    case (endpoint["pricing"] || %{})[key] do
      value when is_binary(value) ->
        case Float.parse(value) do
          {p, _} when p >= 0 -> {:ok, p}
          _ -> :error
        end

      value when is_number(value) and value >= 0 ->
        {:ok, value * 1.0}

      _ ->
        :error
    end
  end

  @doc "The DM model (narrates + referees via tools)."
  @spec dm() :: term()
  def dm, do: build(:dm)

  @doc """
  A cheap model for compaction summaries. Defaults to a lite/flash model
  (overridable via `DRAGONEX_SUMMARIZER_MODEL`). Falls back to a `%Test{}`
  model (deterministic recap text) when no API key is set (tests/dev).
  """
  @spec summarizer() :: term()
  def summarizer, do: build(:summarizer)

  @doc """
  TurnMaster model (D25): decides who acts next via a single tool-call.
  Cheap/fast by default (overridable via `DRAGONEX_TURNMASTER_MODEL`). Falls
  back to `%Test{}` when no API key is set.
  """
  @spec turnmaster() :: term()
  def turnmaster, do: build(:turnmaster)

  @doc "Confirma todos los modelos antes de cambiar la configuración o reiniciar una mesa."
  def prepare_selection(provider, id, reasoning) when provider in [:openrouter, :opencode] do
    cfg = @providers[provider]

    cond do
      not is_binary(id) or String.trim(id) == "" ->
        {:error, dgettext("ui", "Elige un modelo antes de aplicar los ajustes.")}

      not configured?(provider) ->
        {:error, dgettext("ui", "Este proveedor todavía no tiene una clave configurada.")}

      reasoning != :none ->
        {:error,
         dgettext("ui", "Esta mesa necesita un modelo que permita desactivar el razonamiento.")}

      true ->
        try do
          {:ok,
           [
             model: configured_model(provider, cfg, String.trim(id)),
             summarizer:
               configured_model(
                 provider,
                 cfg,
                 System.get_env("DRAGONEX_SUMMARIZER_MODEL", cfg.summarizer)
               ),
             turnmaster_model:
               configured_model(
                 provider,
                 cfg,
                 System.get_env("DRAGONEX_TURNMASTER_MODEL", cfg.turnmaster)
               )
           ]}
        rescue
          ArgumentError ->
            {:error,
             dgettext(
               "ui",
               "No se pudo confirmar un perfil compatible. Elige otro modelo; tu partida conserva su IA actual."
             )}
        end
    end
  end

  def prepare_selection(_, _, _), do: {:error, dgettext("ui", "Elige un proveedor disponible.")}

  @doc "Max output tokens per DM beat (cost cap). DeepSeek v4 flash tends to
  overwrite when given headroom — multiple markdown sections, initiative tables,
  post-action HP recaps — which blows the cap mid-tool-call. 1500 is enough for
  vivid-but-tight narration (3-5 short paragraphs) and forces the model to be
  concise. Bots are capped at 2048 in PCAgent.new/3 (they handle tools + speech)."
  @spec dm_max_tokens() :: pos_integer()
  def dm_max_tokens, do: System.get_env("DRAGONEX_DM_MAX_TOKENS", "1500") |> String.to_integer()

  @doc """
  Output budget for a TurnMaster request, including provider reasoning tokens.
  The default 1024 leaves room for the decision tool call; 256 truncated a
  real request before any decision. DRAGONEX_TURNMASTER_MAX_TOKENS accepts a
  positive integer. Missing, blank or invalid values keep the default.
  """
  @spec turnmaster_max_tokens() :: pos_integer()
  def turnmaster_max_tokens do
    case Integer.parse(String.trim(System.get_env("DRAGONEX_TURNMASTER_MAX_TOKENS", ""))) do
      {tokens, ""} when tokens > 0 -> tokens
      _ -> 1024
    end
  end

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

  # ---------------------------------------------------------------------------
  # Reasoning ("how hard the DM thinks")
  # ---------------------------------------------------------------------------
  # Live profiles are only built with reasoning disabled (`chat_model/5`);
  # `prepare_selection/3` and `build/1` refuse any other effort.

  @doc """
  Reasoning effort for engine requests: always `:none`, the only mode exAgent
  2.x admits for these tables (`chat_model/5`).
  """
  @spec reasoning() :: :none
  def reasoning, do: :none

  # ---------------------------------------------------------------------------
  # OpenRouter upstream provider routing — OPENROUTER_PROVIDER_ORDER
  # ---------------------------------------------------------------------------
  # In multi-provider models (DeepSeek V4 Flash, GLM 5.3 Flash…) the upstream
  # provider changes speed, price and uptime. OpenRouter accepts a top-level
  # `provider` object in the Chat Completions body; it rides in
  # `ModelSettings.extra` (merged by exAgent's OpenAIChat) exactly like the
  # reasoning knob above.

  @doc """
  Parse `OPENROUTER_PROVIDER_ORDER` (CSV of provider slugs) into the ordered
  preference list: split on `,`, trim, downcase, drop empties.
  `"DeepInfra, Relace,,Wafer"` → `["deepinfra", "relace", "wafer"]`.
  """
  @spec parse_provider_order(String.t() | nil) :: [String.t()]
  def parse_provider_order(nil), do: []

  def parse_provider_order(csv) when is_binary(csv) do
    for part <- String.split(csv, ","),
        slug = part |> String.trim() |> String.downcase(),
        slug != "",
        do: slug
  end

  @doc """
  The `ModelSettings.extra` fragment carrying OpenRouter upstream provider
  routing, or `nil` when it must not be sent:

    * unset/blank `OPENROUTER_PROVIDER_ORDER` → `nil` (OpenRouter's default
      routing),
    * active provider other than `:openrouter` → `nil` (OpenCode doesn't
      understand the object).

  When a list exists, `allow_fallbacks: true` always rides along: if every
  listed provider is down, OpenRouter may route elsewhere (uptime first).
  """
  @spec openrouter_provider_extra() :: map() | nil
  def openrouter_provider_extra do
    case {parse_provider_order(System.get_env("OPENROUTER_PROVIDER_ORDER")), provider()} do
      {[], _} ->
        nil

      {_order, :opencode} ->
        nil

      {order, :openrouter} ->
        %{"provider" => %{"order" => order, "allow_fallbacks" => true}}
    end
  end

  @doc """
  The `ModelSettings.extra` map for engine requests (DM beats, PC bots,
  TurnMaster): OpenRouter provider routing, or `nil` to send nothing.
  """
  @spec request_extra() :: map() | nil
  def request_extra, do: openrouter_provider_extra()

  # ---------------------------------------------------------------------------
  # UI helpers (provider catalogue + live model discovery)
  # ---------------------------------------------------------------------------

  @doc """
  The provider catalogue for the Ajustes selector, in stable order. Each entry
  carries its display name, whether its API key is configured, the default DM
  slug and the default summarizer slug.
  """
  @spec providers() :: [map()]
  def providers do
    Enum.map(@providers, fn {id, cfg} ->
      %{
        id: id,
        name: provider_name(id),
        configured: configured?(id),
        dm: cfg.dm,
        summarizer: cfg.summarizer
      }
    end)
  end

  @doc "Human-readable provider name."
  @spec provider_name(:openrouter | :opencode) :: String.t()
  def provider_name(:openrouter), do: "OpenRouter"
  def provider_name(:opencode), do: "OpenCode (Zen/Go)"

  @doc "True when the provider's API key is present and non-blank."
  @spec configured?(:openrouter | :opencode) :: boolean()
  def configured?(id) when id in [:openrouter, :opencode] do
    cfg = @providers[id]
    blank_to_nil(System.get_env(cfg.api_key_env)) != nil
  end

  @doc """
  Connection details for a provider: base URL, api key (or nil) and the env var
  that holds the key. Used by `list_models/1` and the UI.
  """
  @spec provider_info(:openrouter | :opencode) :: map()
  def provider_info(id) when id in [:openrouter, :opencode] do
    cfg = @providers[id]

    %{
      id: id,
      api_key_env: cfg.api_key_env,
      api_key: blank_to_nil(System.get_env(cfg.api_key_env)),
      base_url: base_url(id)
    }
  end

  @doc """
  Fetch the provider's live model catalogue from its `/models` endpoint.

  Returns `{:ok, [model_info]}` (sorted by id, case-insensitive) or
  `{:error, reason}`. When no API key is configured, returns `{:error, :no_key}`
  so the UI can fall back to the catalogue defaults instead of erroring.

  Each `model_info` carries the reasoning metadata the modal needs to render a
  dynamic thinking selector:

    * `:id`            — the model slug.
    * `:reasoning?`    — `true` when the model supports reasoning; `false` when
      it does not; `nil` when unknown (probe failed) → UI shows a generic set.
    * `:efforts`       — the supported effort strings (e.g. `["max","high","low"]`),
      or `nil` if unknown.
    * `:default_effort`— the model's default effort string, or `nil`.
    * `:mandatory`     — `true` when reasoning is always on (no "Off").

  OpenRouter reads this straight from each model's `reasoning` object. OpenCode's
  `/models` exposes nothing, so each model is probed once (cached in ETS) by
  sending a tiny request with `reasoning_effort` and checking whether the model
  emits `reasoning_content`.
  """
  @spec list_models(:openrouter | :opencode) :: {:ok, [map()]} | {:error, term()}
  def list_models(id) when id in [:openrouter, :opencode] do
    info = provider_info(id)

    cond do
      info.api_key == nil ->
        {:error, :no_key}

      true ->
        url = String.trim_trailing(info.base_url, "/") <> "/models"

        case Req.get(
               url,
               [
                 headers: [{"authorization", "Bearer " <> info.api_key}],
                 receive_timeout: 20_000,
                 retry: false
               ] ++ ai_http()
             ) do
          {:ok, %{status: s, body: body}} when s in 200..299 ->
            raw = body["data"] || []

            models =
              case id do
                :openrouter -> Enum.map(raw, &to_model_info(&1, :openrouter))
                :opencode -> build_opencode_models(raw, info)
              end
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq_by(& &1.id)
              |> Enum.sort_by(&String.downcase(&1.id))

            :persistent_term.put(
              {__MODULE__, :catalogue, info.base_url},
              {System.monotonic_time(:millisecond), models}
            )

            {:ok, models}

          {:ok, %{status: s, body: body}} ->
            {:error, {:http, s, body}}

          {:error, reason} ->
            {:error, {:network, reason}}
        end
    end
  end

  # OpenRouter exposes a `reasoning` object per model (supported_efforts, default,
  # mandatory). OpenCode is plain OpenAI-style and carries nothing reasoning-
  # related, so reasoning? is nil → the UI shows a generic effort set.
  defp to_model_info(%{"id" => id} = m, :openrouter) do
    case m["reasoning"] do
      nil ->
        %{
          id: id,
          reasoning?: false,
          efforts: nil,
          default_effort: nil,
          mandatory: false,
          metadata: Map.take(m, ["supported_parameters", "reasoning"])
        }

      r ->
        %{
          id: id,
          reasoning?: true,
          efforts: r["supported_efforts"] || nil,
          default_effort: r["default_effort"] || nil,
          mandatory: r["mandatory"] == true,
          metadata: Map.take(m, ["supported_parameters", "reasoning"])
        }
    end
  end

  defp to_model_info(_, _), do: nil

  # --- OpenCode: curated reasoning catalogue (priv/opencode_reasoning.json) --
  #
  # OpenCode's /models carries NO reasoning metadata, so the effort levels each
  # model accepts are curated per slug in a JSON file (sourced from each
  # provider's docs / user knowledge). Read at runtime so editing the JSON +
  # refresh picks it up without recompiling. The wire param is `reasoning_effort`
  # (OpenAI-compatible; matches DeepSeek/Kimi/OpenAI docs). "Off" sends nothing.

  defp build_opencode_models(raw, _info) do
    catalogue = opencode_reasoning_catalogue()

    for %{"id" => id} <- raw do
      case Map.get(catalogue, id) do
        %{"reasoning" => "yes", "efforts" => efforts, "default" => default}
        when is_list(efforts) ->
          %{id: id, reasoning?: true, efforts: efforts, default_effort: default, mandatory: false}

        %{"reasoning" => "no"} ->
          %{id: id, reasoning?: false, efforts: nil, default_effort: nil, mandatory: false}

        _ ->
          %{id: id, reasoning?: nil, efforts: nil, default_effort: nil, mandatory: false}
      end
    end
  end

  defp opencode_reasoning_catalogue do
    path = Application.app_dir(:dragonex, "priv/opencode_reasoning.json")

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, %{"models" => models}} when is_map(models) -> models
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp base_url(:openrouter), do: "https://openrouter.ai/api/v1"

  defp base_url(:opencode) do
    if opencode_plan() == :zen,
      do: "https://opencode.ai/zen/v1",
      else: "https://opencode.ai/zen/go/v1"
  end

  defp opencode_plan do
    case System.get_env("OPENCODE_PLAN", "go") |> to_string() |> String.downcase() do
      "zen" -> :zen
      _ -> :go
    end
  end

  # ---------------------------------------------------------------------------
  # Provider dispatch
  # ---------------------------------------------------------------------------

  # Build a model struct for the given role (:dm | :summarizer | :turnmaster)
  # from the active provider's catalogue row. A present-but-blank API key (e.g.
  # `OPENCODE_API_KEY=` copied from the .example template) must NOT take the live
  # path — empty string is truthy in Elixir, so it would otherwise build a real
  # client that 401s.
  @spec build(:dm | :summarizer | :turnmaster) :: term()
  defp build(role) do
    cfg = @providers[provider()]

    case blank_to_nil(System.get_env(cfg.api_key_env)) do
      nil -> test_model(role)
      _api_key -> new_model(cfg, role)
    end
  end

  defp new_model(cfg, role) do
    id =
      case role do
        :dm -> model()
        :summarizer -> System.get_env("DRAGONEX_SUMMARIZER_MODEL", cfg.summarizer)
        :turnmaster -> System.get_env("DRAGONEX_TURNMASTER_MODEL", cfg.turnmaster)
      end

    unless reasoning() == :none,
      do: raise(ArgumentError, "exAgent v2 admite esta partida con razonamiento desactivado.")

    configured_model(provider(), cfg, id)
  end

  defp configured_model(provider, cfg, id) do
    metadata = catalogue_metadata!(provider, id)
    chat_model(provider, id, System.fetch_env!(cfg.api_key_env), metadata)
  end

  defp catalogue_metadata!(provider, id) do
    result =
      case :persistent_term.get({__MODULE__, :catalogue, base_url(provider)}, nil) do
        {at, models} ->
          if System.monotonic_time(:millisecond) - at < 300_000,
            do: {:ok, models},
            else: list_models(provider)

        nil ->
          list_models(provider)
      end

    with {:ok, models} <- result,
         %{metadata: metadata} <- Enum.find(models, &(&1.id == id)) do
      metadata
    else
      _ ->
        raise ArgumentError,
              "No hay un perfil confirmado para #{id} en el catálogo del proveedor."
    end
  end

  # Extra Req options for provider calls (`config :dragonex, :ai_http`): tests
  # plug a stub there so no request leaves the machine.
  defp ai_http, do: Application.get_env(:dragonex, :ai_http, [])

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp test_model(:dm),
    do: %Models.Test{label: "(TestModel) set the provider's API key for a live DM."}

  defp test_model(:summarizer),
    do: %Models.Test{label: "(recap of earlier turns)"}

  # Fixed label (no tools) → beat succeeds with no decision → Game soft-falls
  # back to WorldDriven. Keeps the offline suite green without scripting TM in
  # every test. Do NOT use label: "" — empty text trips "Please respond" retries.
  defp test_model(:turnmaster),
    do: %Models.Test{label: "(turnmaster: use WorldDriven)"}
end
