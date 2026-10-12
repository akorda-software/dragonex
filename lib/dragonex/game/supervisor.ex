defmodule Dragonex.Game.Supervisor do
  @moduledoc """
  Owns the live `Dragonex.Game` processes (one per partida).

  A Game process is started on demand (when a partida is opened) and stops when
  the partida is closed/paused; its state is always safe in Postgres, so a fresh
  process rehydrates the same `game_id` after a crash. The `DynamicSupervisor`
  lets any number of partidas run concurrently, each registered by `game_id`.
  Each table has its own supervisor and restart budget, so repeated failures
  in one table cannot close the others.
  """

  use DynamicSupervisor
  alias Dragonex.Game.TableSupervisor

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
    case DynamicSupervisor.start_child(__MODULE__, {TableSupervisor, {game_id, opts}}) do
      {:ok, owner} ->
        TableSupervisor.game_pid(owner)

      {:error, {:already_started, owner}} ->
        case TableSupervisor.game_pid(owner) do
          {:ok, pid} -> {:error, {:already_started, pid}}
          other -> other
        end

      {:error, {:shutdown, {:failed_to_start_child, _child, reason}}} ->
        {:error, reason}

      other ->
        other
    end
  end

  @doc "Stop a Game process (its state is already persisted)."
  @spec stop_game(term()) :: :ok | {:error, :not_found}
  def stop_game(game_id) do
    case TableSupervisor.whereis(game_id) do
      owner when is_pid(owner) ->
        DynamicSupervisor.terminate_child(__MODULE__, owner)

      nil ->
        # Existing development Games may predate the table supervisors.
        case whereis(game_id) do
          nil -> {:error, :not_found}
          pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
        end
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
