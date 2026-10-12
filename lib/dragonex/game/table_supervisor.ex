defmodule Dragonex.Game.TableSupervisor do
  @moduledoc """
  Gives one table its own restart budget. Exhausting it closes this table's
  processes without restarting the global manager or other tables.
  """
  use Supervisor

  @registry Dragonex.Game.SupervisorRegistry

  def child_spec({game_id, _opts} = args) do
    %{
      id: {__MODULE__, game_id},
      start: {__MODULE__, :start_link, [args]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link({game_id, opts}) do
    Supervisor.start_link(__MODULE__, {game_id, opts},
      name: {:via, Registry, {@registry, game_id}}
    )
  end

  @impl true
  def init({game_id, opts}) do
    child = Dragonex.Game.child_spec({game_id, opts}) |> Map.put(:significant, true)

    # Normal Game shutdown must also remove the empty table supervisor. A
    # transient abnormal exit is restarted here, within this table's budget.
    Supervisor.init([child], strategy: :one_for_one, auto_shutdown: :any_significant)
  end

  def whereis(game_id) do
    case Registry.lookup(@registry, game_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def game_pid(supervisor) do
    case Supervisor.which_children(supervisor) do
      [{_, pid, :worker, _}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end
end
