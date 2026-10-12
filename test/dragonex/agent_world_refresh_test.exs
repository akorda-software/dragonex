defmodule Dragonex.AgentWorldRefreshTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{AgentInstructions, Archetypes, World}
  alias Dragonex.Test.ModelMessages
  alias ExAgent.{Message, Message.Part, Session}
  alias ExAgent.Session.SharedState

  @prefix "WORLD VIGENTE:"

  defp state(shared, step) do
    %{
      agent: %{instructions: [%Part.System{content: "Reglas del personaje."}]},
      messages: [Message.new_request([%Part.User{content: "WORLD antiguo: no tengo farol."}])],
      request_messages: nil,
      run_step: step,
      deps: %{
        state: shared,
        beat: %{actor: "Thane"},
        participant_kinds: %{"Thane" => :human}
      }
    }
  end

  defp snapshots(messages) do
    messages
    |> ModelMessages.project()
    |> Enum.filter(&(&1["role"] == "system" and String.starts_with?(&1["content"], @prefix)))
  end

  test "continuations read the committed inventory and replace only their transient snapshot" do
    world = World.new(characters: %{"Thane" => Archetypes.fighter()})

    session =
      start_supervised!(
        {Session, shared_state: world, policy: :round_robin, participants: [p("Thane")]}
      )

    assert {:ok, _} = Session.start(session)
    shared = SharedState.new(session, "Thane")
    assert {:ok, _} = SharedState.propose_change(shared, World.grant_item("Thane", "farol", 1))
    original = state(shared, 2)
    committed = SharedState.read(shared)
    projected = AgentInstructions.before_model_request(AgentInstructions, original)
    assert [%{"content" => fresh}] = snapshots(projected.request_messages)
    assert fresh =~ "farol ×1" and fresh =~ "jugadores humanos"
    assert Map.delete(projected, :request_messages) == Map.delete(original, :request_messages)
    assert SharedState.read(shared) == committed
    assert snapshots(original.messages) == []

    assert {:ok, _} =
             SharedState.propose_change(shared, World.grant_item("Thane", "farol", 1, true))

    updated = AgentInstructions.before_model_request(AgentInstructions, projected)
    assert [%{"content" => current}] = snapshots(updated.request_messages)
    assert current =~ "farol ×2"
    refute current =~ "farol ×1"
    assert updated.messages == original.messages and updated.run_step == 2
  end

  test "first requests and contexts outside a game beat do not read the shared handle" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    original = state(SharedState.new(dead, "Thane"), 1)

    for candidate <- [
          original,
          %{original | run_step: 2, deps: Map.delete(original.deps, :beat)},
          %{original | run_step: 2, deps: Map.delete(original.deps, :participant_kinds)},
          %{original | run_step: 2, deps: %{original.deps | beat: %{actor: ""}}}
        ] do
      projected = AgentInstructions.before_model_request(AgentInstructions, candidate)
      assert snapshots(projected.request_messages) == []
      assert projected.messages == candidate.messages
    end
  end

  test "a non-World shared state is not rendered as a game snapshot" do
    session =
      start_supervised!(
        {Session, shared_state: %{unrelated: true}, policy: :round_robin, participants: []}
      )

    original = state(SharedState.new(session, "Thane"), 2)
    projected = AgentInstructions.before_model_request(AgentInstructions, original)
    assert snapshots(projected.request_messages) == []
    assert projected.messages == original.messages
  end
end
