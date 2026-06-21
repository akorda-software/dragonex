defmodule Dragones.Flows.SessionPersistenceTest do
  @moduledoc """
  Flow 7b — the WORLD now survives a crash too.

  exAgent 1.0 (Session store) checkpoints shared_state + turn position and
  rehydrates on restart. This closes the gap the spike surfaced in Flow 7 (where
  only the DM's conversation history persisted).

  Note on JSON portability: the framework stores shared_state as strict JSON, so
  a world carried across a restart comes back as a plain map with STRING keys.
  A struct-based world (like the in-memory Dragones.World) would need a codec to
  round-trip back into the struct — a real-app concern. Here we use a plain
  JSON-native world to validate the feature itself.
  """

  use ExUnit.Case, async: false

  alias ExAgent.Session
  alias ExAgent.Session.Participant
  alias ExAgent.Store

  @ets {ExAgent.Store.ETS, ExAgent.Store.ETS}

  # A plain JSON-native world (string keys) — survives JSON round-trip cleanly.
  defp new_world do
    %{"scene" => "a quiet crossroads", "log" => [], "round" => 1}
  end

  test "the world + turn position survive a crash/restart" do
    id = "drag-sess-#{:erlang.unique_integer([:positive])}"

    {:ok, a} =
      Session.start_link(
        shared_state: new_world(),
        policy: :round_robin,
        participants: [Participant.new(id: "fighter"), Participant.new(id: "goblin")],
        session_id: id,
        store: :ets
      )

    {:ok, "fighter"} = Session.start(a)

    # Fighter advances the scene and the log.
    assert {:ok, _, "goblin"} =
             Session.take_turn(a, "fighter", fn w ->
               {:ok,
                %{"w" => w, "scene" => "torchlit tavern", "log" => ["fighter enters" | w["log"]]}}
             end)

    :ok = GenServer.stop(a, :normal)

    # A new session with the same id + store restores the world AND the turn.
    {:ok, b} =
      Session.start_link(
        shared_state: new_world(),
        policy: :round_robin,
        participants: [Participant.new(id: "fighter"), Participant.new(id: "goblin")],
        session_id: id,
        store: :ets
      )

    world = Session.read_state(b)
    assert world["scene"] == "torchlit tavern"
    assert world["log"] == ["fighter enters"]
    # Turn position restored: it's the goblin's turn now.
    assert Session.current(b) == "goblin"

    # The game keeps going from where it left off.
    assert {:ok, _, "fighter"} =
             Session.take_turn(b, "goblin", fn w ->
               {:ok, %{w | "log" => ["goblin snarls" | w["log"]]}}
             end)

    assert Session.read_state(b)["log"] == ["goblin snarls", "fighter enters"]

    Store.delete_session_snapshot(@ets, id)
  end
end
