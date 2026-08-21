defmodule Dragonex.ModelConfig do
  @moduledoc """
  Runtime override for the active provider, DM model and reasoning level.

  `Dragonex.Models` normally reads provider/model from env vars
  (`DRAGONEX_PROVIDER`, `DRAGONEX_MODEL`, …) at Game start. This GenServer lets
  the in-game Ajustes modal override those **at runtime**, so you can A/B-test
  providers/models/thinking without editing `.env.dev` or restarting the app.

  Overrides are **ephemeral** (in-memory): a full app restart falls back to the
  env defaults. The override is **app-global** (not per-partida): changing it
  affects the next Game that (re)starts. The modal applies a change by
  restarting the current partida's `Dragonex.Game` process, which rehydrates the
  same `game_id` from Postgres with the new model wired in.

  Effective value for a field = the override when set, else the env default
  resolved by `Dragonex.Models`.
  """

  use GenServer

  @name __MODULE__

  @type provider :: :openrouter | :opencode
  @type reasoning :: :none | String.t()

  defstruct provider: nil, model: nil, reasoning: nil

  @type t :: %__MODULE__{
          provider: provider() | nil,
          model: String.t() | nil,
          reasoning: reasoning() | nil
        }

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: @name)

  @doc "Current override state (fields are `nil` when unset → env default applies)."
  @spec get() :: t()
  def get, do: GenServer.call(@name, :get)

  @doc """
  Set one or more override fields.

    * `:provider`  — `:openrouter | :opencode`
    * `:model`     — DM model slug (string); `nil`/`""` clears it
    * `:reasoning` — `:none` or an effort string (`"low"`, `"medium"`, `"high"`,
      `"minimal"`, `"xhigh"`, `"max"`, … — whatever the selected model supports)

  Unknown keys are ignored. Blank model strings are normalized to `nil`.
  """
  @spec set(keyword()) :: :ok
  def set(fields) when is_list(fields), do: GenServer.call(@name, {:set, fields})

  @doc "Clear every override (back to env defaults)."
  @spec clear() :: :ok
  def clear, do: GenServer.call(@name, :clear)

  # --- callbacks ------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:set, fields}, _from, state) do
    new_state =
      Enum.reduce(fields, state, fn
        {:provider, p}, acc when p in [:openrouter, :opencode] -> %{acc | provider: p}
        {:provider, _}, acc -> acc
        {:model, m}, acc -> %{acc | model: blank_to_nil(m)}
        {:reasoning, :none}, acc -> %{acc | reasoning: :none}
        {:reasoning, r}, acc when is_binary(r) -> %{acc | reasoning: r}
        {:reasoning, nil}, acc -> %{acc | reasoning: nil}
        {:reasoning, _}, acc -> acc
        _, acc -> acc
      end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:clear, _from, _state), do: {:reply, :ok, %__MODULE__{}}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: String.trim(s)
  defp blank_to_nil(other), do: other
end
