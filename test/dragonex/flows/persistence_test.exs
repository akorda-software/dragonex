defmodule Dragonex.Flows.PersistenceTest do
  @moduledoc """
  Flow 7 — campaign durability.

  Validates that a DM agent (ExAgent.Server) checkpoints its CONVERSATION history
  to the store and rehydrates after a crash — so a restarted DM still remembers
  prior narration context.

  GAP SURFACED: the Server persists the agent's message history, but the game
  WORLD lives in the ExAgent.Session (in-memory). A durable campaign needs the
  World persisted too — the Store behaviour declares session-snapshot callbacks
  but they aren't wired yet. That's a real product decision for the full app
  (persist the World alongside the DM, or reconstruct it from the history).
  """

  use ExUnit.Case, async: false

  alias ExAgent.{AgentSupervisor, Server, Store}
  alias ExAgent.Models.Test

  @ets {ExAgent.Store.ETS, ExAgent.Store.ETS}

  test "a crashed DM rehydrates its conversation history from the store" do
    id = "persist-#{:erlang.unique_integer([:positive])}"
    name = :"dm_#{id}"

    {:ok, pid} =
      AgentSupervisor.start_agent(
        agent:
          ExAgent.new(
            model: %Test{script: ["turn one", "turn two", "turn three"]},
            instructions: "You are the DM."
          ),
        agent_id: id,
        store: :ets,
        name: name
      )

    # Two narration turns → history grows to 4 messages, checkpointed.
    assert {:ok, _} = Server.chat(name, "the party enters the dungeon")
    assert {:ok, _} = Server.chat(name, "they meet a goblin")
    assert length(Server.history(name)) == 4

    # Crash the DM. The supervisor restarts it; the store rehydrates history.
    Process.exit(pid, :kill)
    assert wait_for_restart(name)

    assert Process.whereis(name) != pid
    # The DM remembers both prior turns (the conversation survived).
    assert length(Server.history(name)) == 4

    # And it keeps narrating on top of the restored history. NOTE: the model
    # struct restarts from the live template (its script index is NOT persisted),
    # so this returns the template's first scripted reply — the history is what's
    # restored, not the model's internal position.
    assert {:ok, %{output: "turn one"}} = Server.chat(name, "the goblin attacks")

    Store.delete_agent_snapshot(@ets, id)
    AgentSupervisor.stop_agent(Process.whereis(name))
  end

  defp wait_for_restart(name, tries \\ 400) do
    cond do
      tries <= 0 ->
        false

      Process.whereis(name) != nil and ready?(name) ->
        true

      true ->
        Process.sleep(5)
        wait_for_restart(name, tries - 1)
    end
  end

  defp ready?(name) do
    try do
      %{status: _} = Server.health(name)
      true
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end
end
