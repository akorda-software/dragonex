defmodule Dragonex.Test.Sandbox do
  @moduledoc """
  Keeps shared SQL ownership alive until ExUnit has stopped its supervised
  processes. LiveViews and agent Tasks can outlive the test process itself.
  """
  def start_shared! do
    existing = live_games() |> Map.values() |> MapSet.new()
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Dragonex.Repo, shared: true)

    ExUnit.Callbacks.on_exit(fn ->
      # LiveViews start Games under the application's DynamicSupervisor.
      # Those games are not children of ExUnit's per-test supervisor.
      for {id, game} <- live_games(), not MapSet.member?(existing, game) do
        Dragonex.Test.GameFixture.quiesce(game)
        Dragonex.Game.Supervisor.stop_game(id)
      end

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp live_games do
    Dragonex.Game.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new()
  end
end
