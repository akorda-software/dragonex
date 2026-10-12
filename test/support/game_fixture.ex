defmodule Dragonex.Test.GameFixture do
  @moduledoc """
  Starts an ExUnit-owned Game with a shutdown fence registered after it.
  ExUnit stops children in reverse order, so the fence first pauses the game
  and lets its current offline beat finish before Game and SQL ownership end.
  """
  use GenServer
  alias Dragonex.Game

  def start!(spec) do
    game = ExUnit.Callbacks.start_supervised!(spec)
    ExUnit.Callbacks.start_supervised!({__MODULE__, game})
    game
  end

  def child_spec(game) do
    %{
      id: {__MODULE__, game},
      start: {__MODULE__, :start_link, [game]},
      restart: :temporary,
      shutdown: 10_000
    }
  end

  def start_link(game), do: GenServer.start_link(__MODULE__, game)

  @impl true
  def init(game) do
    Process.flag(:trap_exit, true)
    {:ok, %{game: game, monitor: Process.monitor(game)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{game: game}), do: quiesce(game)

  def quiesce(game) do
    if Process.alive?(game) do
      Game.pause(game)
      await_quiet(game, System.monotonic_time(:millisecond) + 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp await_quiet(game, deadline) do
    if match?(%Dragonex.Game.Beat{}, :sys.get_state(game).busy) do
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(10)
        await_quiet(game, deadline)
      end
    else
      :ok
    end
  end
end
