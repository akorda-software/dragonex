defmodule Dragonex.FactAgencyTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Monsters, Tools, World}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  defp context do
    world =
      World.new(
        characters: %{
          "Mara" => Archetypes.fighter(name: "Mara"),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue(),
          "Lyra del Muelle" => Monsters.bandit(name: "Lyra del Muelle")
        }
      )

    session =
      start_session(
        world: world,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Mara"), p("Lyra"), p("Vex")]
      )

    assert {:ok, "dm"} = Session.start(session)
    {session, %{deps: %{state: SharedState.new(session, "dm")}}, world}
  end

  test "a fact cannot impose a PC action, group move or passive group decision" do
    {session, ctx, before} = context()

    for fact <- [
          "Lyra se acerca a la puerta.",
          "El grupo cruza el umbral.",
          "La decisión queda tomada entre vosotros: iremos al pueblo.",
          "Nos miramos un momento."
        ] do
      assert {:error, "RECHAZADO" <> _} = Tools.establish_fact(ctx, fact)
      assert Session.read_state(session) == before
    end
  end

  test "NPC actions, qualified groups and quoted invitations remain durable facts" do
    {session, ctx, before} = context()

    facts = [
      "Lyra del Muelle abre la puerta.",
      "El grupo de guardias cruza el puente.",
      "La decisión queda tomada entre los guardias.",
      "Sena dice: «Os miráis cuando queráis»."
    ]

    for fact <- facts, do: assert({:ok, "hecho registrado"} == Tools.establish_fact(ctx, fact))
    world = Session.read_state(session)
    assert world.facts == facts

    assert Map.drop(world, [:facts, :scene_refresh_pending]) ==
             Map.drop(before, [:facts, :scene_refresh_pending])
  end

  test "PCs cannot confirm their own discoveries or actions as canonical world facts" do
    {session, _ctx, before} = context()

    for actor <- ["Mara", "Lyra", "Vex"] do
      assert {:ok, ^actor} = Session.handoff(session, actor)
      ctx = %{deps: %{state: SharedState.new(session, actor)}}

      for fact <- [
            "#{actor} halló un hilo de lana oscura enganchado en una espina de retama.",
            "Un hilo de lana oscura está enganchado en una espina de retama.",
            "#{actor} se acerca a la puerta."
          ] do
        assert {:error, "RECHAZADO — solo el DM" <> _} = Tools.establish_fact(ctx, fact)
        assert Session.read_state(session) == before
      end
    end
  end

  test "a non-DM handle is rejected before reading or proposing any shared state" do
    for actor <- [nil, "DM", "Mara"] do
      ctx = %{deps: %{state: %SharedState{participant_id: actor, session: self()}}}
      assert {:error, "RECHAZADO — solo el DM" <> _} = Tools.establish_fact(ctx, "Un hilo.")
    end
  end

  test "changing the scene cannot bypass the DM's confirmation of a discovery" do
    {session, _, before} = context()

    for actor <- ["Mara", "Lyra", "Vex"] do
      assert {:ok, ^actor} = Session.handoff(session, actor)
      ctx = %{deps: %{state: SharedState.new(session, actor)}}

      assert {:error, "RECHAZADO — solo el DM" <> _} =
               Tools.set_scene(ctx, "Un hilo de lana oscura cuelga de una espina de retama.")

      assert Session.read_state(session) == before
    end
  end

  test "scrubbing still removes model labels and numbers before a legitimate fact is saved" do
    {session, ctx, _before} = context()

    assert {:ok, "hecho registrado"} =
             Tools.establish_fact(
               ctx,
               "[DM]: La posadera entrega un pergamino. El jefe queda en 3/7 pg."
             )

    assert [fact] = Session.read_state(session).facts
    assert fact =~ "La posadera entrega un pergamino"
    refute fact =~ "[DM]"
    refute fact =~ "3/7"
  end
end
