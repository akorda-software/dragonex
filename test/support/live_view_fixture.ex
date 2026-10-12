defmodule Dragonex.Test.LiveViewFixture do
  @moduledoc """
  Mounts LiveViews with a shutdown fence registered after their channel.
  ExUnit stops children in reverse order: the fence requests a synchronous
  stop, allowing an in-progress SQL query to return before the channel exits.
  This protects the shared Sandbox connection used by the Game and other views.
  """
  use GenServer

  defmacro live(conn, path \\ nil, opts \\ []) do
    quote do
      require Phoenix.LiveViewTest

      Phoenix.LiveViewTest.live(unquote(conn), unquote(path), unquote(opts))
      |> Dragonex.Test.LiveViewFixture.manage()
    end
  end

  defmacro live_isolated(conn, module, opts \\ []) do
    quote do
      require Phoenix.LiveViewTest

      Phoenix.LiveViewTest.live_isolated(unquote(conn), unquote(module), unquote(opts))
      |> Dragonex.Test.LiveViewFixture.manage()
    end
  end

  defmacro follow_redirect(reason, conn, to \\ nil) do
    quote do
      require Phoenix.LiveViewTest

      Phoenix.LiveViewTest.follow_redirect(unquote(reason), unquote(conn), unquote(to))
      |> Dragonex.Test.LiveViewFixture.manage()
    end
  end

  def manage({:ok, %Phoenix.LiveViewTest.View{pid: pid}, _html} = result) do
    case ExUnit.Callbacks.start_supervised({__MODULE__, pid}) do
      {:ok, _fence} -> result
      {:error, {:already_started, _fence}} -> result
      other -> raise "could not supervise LiveView shutdown: #{inspect(other)}"
    end
  end

  def manage(other), do: other

  def child_spec(view) do
    %{
      id: {__MODULE__, view},
      start: {__MODULE__, :start_link, [view]},
      restart: :temporary,
      shutdown: 15_000
    }
  end

  def start_link(view), do: GenServer.start_link(__MODULE__, view)

  @impl true
  def init(view) do
    Process.flag(:trap_exit, true)
    {:ok, %{view: view, monitor: Process.monitor(view)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{view: view}) do
    if Process.alive?(view), do: GenServer.stop(view, :normal, 10_000)
    :ok
  catch
    :exit, reason ->
      # A redirect or transport closure may finish the channel between the
      # liveness check and the synchronous stop. A live timeout still fails.
      if Process.alive?(view), do: exit(reason), else: :ok
  end
end
