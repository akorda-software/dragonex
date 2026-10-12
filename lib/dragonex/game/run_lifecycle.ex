defmodule Dragonex.Game.RunLifecycle do
  @moduledoc """
  Cancels game-owned processes when their owner disappears, including exAgent
  run tasks which are supervised independently of their agent server.

  Monitors preserve fault isolation: a failed model request cannot kill the
  Game. Each watcher exits when its targets finish or an owner disappears.
  """
  use ExAgent.Capability

  @impl true
  def before_model_request(_cap, state) do
    ensure_alive!(state.deps)
    owners = owners(state.deps)

    if owners != [] and Process.get({__MODULE__, :watcher}) == nil do
      Process.put({__MODULE__, :watcher}, watch(owners, [self()]))
    end

    state
  end

  @impl true
  def after_model_request(_cap, state) do
    ensure_alive!(state.deps)
    state
  end

  @impl true
  def before_tool_execute(_cap, ctx, call) do
    ensure_alive!(ctx.deps)
    call
  end

  def alive?(deps), do: Enum.all?(owners(deps), &Process.alive?/1)

  def watch(owners, targets) do
    spawn(fn ->
      owner_refs = MapSet.new(Enum.map(owners, &Process.monitor/1))
      target_refs = Map.new(targets, &{Process.monitor(&1), &1})
      await(owner_refs, target_refs)
    end)
  end

  defp await(_owners, targets) when map_size(targets) == 0, do: :ok

  defp await(owners, targets) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        if MapSet.member?(owners, ref) do
          Enum.each(Map.values(targets), &Process.exit(&1, :shutdown))
        else
          await(owners, Map.delete(targets, ref))
        end
    end
  end

  defp ensure_alive!(deps) do
    if not alive?(deps), do: exit(:shutdown)
  end

  defp owners(deps) when is_map(deps) do
    [:game_owner, :beat_owner]
    |> Enum.map(&Map.get(deps, &1))
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  defp owners(_), do: []
end
