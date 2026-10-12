defmodule Dragonex.ControlRejectionGuidanceTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Monsters, Tools, World}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  defp context(opts \\ []) do
    world =
      World.new(
        characters: %{
          "Thane" => Archetypes.fighter(),
          "Lyra" => Archetypes.wizard(),
          "Goblin" => Monsters.goblin(name: "Goblin")
        }
      )

    world =
      if opts[:absent],
        do: %{world | absent_characters: %{"Goblin" => "Fuera de la sala"}},
        else: world

    session =
      start_session(
        world: world,
        policy: :round_robin,
        participants: [p("dm"), p("Thane"), p("Lyra")]
      )

    assert {:ok, "dm"} = Session.start(session)
    {session, world}
  end

  defp ctx(session, proposer),
    do: %{
      deps: %{
        state: SharedState.new(session, proposer),
        roller: fn _ -> flunk("rejected actors must not roll") end
      }
    }

  test "an unregistered monster gets a missing-sheet directive, never a suggestion to attack as dm" do
    {session, before} = context()

    assert {:error, error} =
             Tools.make_attack(ctx(session, "dm"), "esqueleto", "Thane", "shortsword", "normal")

    assert error =~ "no existe" and error =~ "esqueleto" and error =~ "spawn_monster"
    refute error =~ "como dm"
    refute error =~ "DEBE ser \"dm\""
    assert Session.read_state(session) == before
  end

  test "dm denotes a controller and a rejected PC actor gets actual controlled names" do
    {session, before} = context()

    for actor <- ["dm", "Thane"] do
      assert {:error, error} =
               Tools.make_attack(ctx(session, "dm"), actor, "Lyra", "shortsword", "normal")

      assert error =~ "controlador" and error =~ "Goblin"
      refute error =~ "DEBE ser \"dm\""
      assert Session.read_state(session) == before
    end
  end

  test "an absent actor stays absent and cannot be recreated as an unknown monster" do
    {session, before} = context(absent: true)

    assert {:error, error} =
             Tools.make_attack(ctx(session, "dm"), "Goblin", "Thane", "shortsword", "normal")

    assert error =~ "fuera de escena"
    refute error =~ "spawn_monster"
    assert Session.read_state(session) == before
  end

  test "a manual PC still gets their own name for an unauthorized companion action" do
    {session, before} = context()
    assert {:ok, "Thane"} = Session.handoff(session, "Thane")

    assert {:error, error} =
             Tools.make_attack(ctx(session, "Thane"), "Lyra", "Goblin", "longsword", "normal")

    assert error =~ "como Thane"
    assert Session.read_state(session) == before
  end
end
