defmodule Dragonex.Game.Supervisor do
  @moduledoc """
  Owns the live `Dragonex.Game` processes (one per partida).

  A Game process is started on demand (when a partida is opened) and stops when
  the partida is closed/paused; its state is always safe in Postgres, so a fresh
  process rehydrates the same `game_id` after a crash. The `DynamicSupervisor`
  lets any number of partidas run concurrently, each registered by `game_id`.
  """

  use DynamicSupervisor

  @registry Dragonex.Game.Registry

  @doc "Start the dynamic supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a Game process for `game_id` (idempotent: if one already runs, returns
  `{:error, {:already_started, pid}}`). The process rehydrates from Postgres.
  """
  @spec start_game(term(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_game(game_id, opts \\ []) do
    spec = {Dragonex.Game, {game_id, opts}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Stop a Game process (its state is already persisted)."
  @spec stop_game(term()) :: :ok | {:error, :not_found}
  def stop_game(game_id) do
    case whereis(game_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc "The pid of the running Game process for `game_id`, if any."
  @spec whereis(term()) :: pid() | nil
  def whereis(game_id) do
    case Registry.lookup(@registry, game_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Whereis-via helper for the Game GenServer's `:name`."
  @spec via(term()) :: {:via, module(), term()}
  def via(game_id), do: {:via, Registry, {@registry, game_id}}
end
