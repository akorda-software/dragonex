defmodule Dragonex.PersistenceTest do
  @moduledoc """
  The real proof of gap #1: a `Dragonex.World` (full struct tree — Characters,
  Weapons, Spells, combat phase, log) survives a session crash/restart through
  the `Dragonex.Store.Coded` wrapper. On rehydrate the app gets structs back,
  not plain maps.
  """

  use ExUnit.Case, async: false

  alias Dragonex.{Archetypes, Monsters, Store.Coded, TurnPolicy.WorldDriven, World}
  alias ExAgent.{Session, Session.Participant}

  @store {Coded, ExAgent.Store.ETS}

  test "the world struct tree survives a session crash/restart" do
    sid = "coded-persist-#{System.unique_integer([:positive])}"

    world =
      World.new()
      |> add(World.add_character(Archetypes.fighter()))
      |> add(World.add_character(Monsters.goblin()))

    {:ok, s1} =
      Session.start_link(
        shared_state: world,
        shared_state_codec: Dragonex.Store.WorldCodec,
        store: @store,
        policy: {WorldDriven, dm: "dm"},
        participants: [
          Participant.new(id: "dm", kind: :agent),
          Participant.new(id: "Thane", kind: :human)
        ],
        session_id: sid
      )

    assert {:ok, _} = Session.start(s1)

    # The DM's turn: start combat and nick the goblin — forces a checkpoint.
    assert {:ok, _, _} =
             Session.take_turn(s1, "dm", fn w ->
               {:ok, w2} = World.begin_combat(["Thane", "goblin"]).(w)
               World.apply_damage("goblin", 3).(w2)
             end)

    assert %World{phase: :combat} = Session.read_state(s1)
    committed = Session.read_state(s1)
    cursor = Session.current(s1)

    # "Crash".
    :ok = GenServer.stop(s1, :normal)

    # Rehydrate from the same store + session id.
    {:ok, s2} =
      Session.start_link(
        shared_state_codec: Dragonex.Store.WorldCodec,
        store: @store,
        policy: {WorldDriven, dm: "dm"},
        participants: [
          Participant.new(id: "dm", kind: :agent),
          Participant.new(id: "Thane", kind: :human)
        ],
        session_id: sid
      )

    rehydrated = Session.read_state(s2)

    # Structs came back, not a plain JSON map.
    assert %World{} = rehydrated
    assert rehydrated == committed
    assert Session.current(s2) == cursor
    assert rehydrated.phase == :combat
    assert rehydrated.initiative_order == ["Thane", "goblin"]
    assert %Dragonex.Character{hp: 12, ac: 16} = rehydrated.characters["Thane"]
    assert %Dragonex.Character{hp: 4, ac: 15} = rehydrated.characters["goblin"]
    assert {"dm", "combat begins: Thane → goblin"} in rehydrated.log

    GenServer.stop(s2, :normal)
    ExAgent.Store.delete_session_snapshot(@store, sid)
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end
end
