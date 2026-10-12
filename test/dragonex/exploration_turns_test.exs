defmodule Dragonex.ExplorationTurnsTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, ExplorationTurns, World}

  defp party do
    characters = [
      Archetypes.fighter(),
      %{Archetypes.fighter() | name: "Nera"},
      Archetypes.wizard(),
      Archetypes.rogue()
    ]

    world =
      Enum.reduce(characters, World.new(), fn c, w -> elem(World.add_character(c).(w), 1) end)

    participants = %{
      "dm" => %{kind: :other},
      "Thane" => %{kind: :human},
      "Nera" => %{kind: :human},
      "Lyra" => %{kind: :ai},
      "Vex" => %{kind: :ai}
    }

    {world, participants, %{"Lyra" => :agent, "Vex" => :agent}}
  end

  defp turn(actor, phase \\ "exploration", kind \\ "main") do
    %{
      type: :turn,
      actor: actor,
      payload: %{"kind" => "start", "phase" => phase, "turn_kind" => kind}
    }
  end

  test "DM answers and multiple narration fragments do not erase an AI turn; a human turn does" do
    {world, participants, agents} = party()
    events = [turn("Thane"), turn("Lyra"), turn("dm")]
    events = events ++ List.duplicate(%{type: :narration, actor: "Lyra", payload: %{}}, 10)
    context = ExplorationTurns.context(world, participants, agents, events)

    assert context.ai_acted == ["Lyra"]
    assert ExplorationTurns.human_after_repeat(context, "Lyra") == "Nera"
    refute ExplorationTurns.human_after_repeat(context, "Vex")
    refute ExplorationTurns.human_due(context)

    after_human = ExplorationTurns.context(world, participants, agents, events ++ [turn("Nera")])
    assert after_human.ai_acted == []
    refute ExplorationTurns.human_after_repeat(after_human, "Lyra")
    refute ExplorationTurns.human_after_ai(after_human)
  end

  test "a full party allows five distinct companions then returns to its human" do
    names = Enum.map(1..5, &"Compañero #{&1}")
    characters = [Archetypes.fighter() | Enum.map(names, &%{Archetypes.fighter() | name: &1})]

    world =
      Enum.reduce(characters, World.new(), fn c, w -> elem(World.add_character(c).(w), 1) end)

    participants = Map.new(names, &{&1, %{kind: :ai}}) |> Map.put("Thane", %{kind: :human})
    agents = Map.new(names, &{&1, :agent})
    events = Enum.flat_map(names, &[turn(&1), turn("dm")])

    full = ExplorationTurns.context(world, participants, agents, events)
    assert full.ai_acted == names
    assert ExplorationTurns.human_due(full) == "Thane"
    partial = ExplorationTurns.context(world, participants, agents, Enum.drop(events, -2))
    refute ExplorationTurns.human_due(partial)
    assert ExplorationTurns.human_after_repeat(partial, hd(names)) == "Thane"
  end

  test "autoplayed humans count as companions and cannot be selected as manual players" do
    {world, participants, agents} = party()
    agents = Map.put(agents, "Thane", :auto_agent)
    events = Enum.map(["Thane", "Lyra", "Vex", "dm"], &turn/1)
    context = ExplorationTurns.context(world, participants, agents, events)
    assert context.humans == ["Nera"]
    assert context.ai == ["Lyra", "Thane", "Vex"]
    assert ExplorationTurns.human_due(context) == "Nera"

    automated =
      ExplorationTurns.context(world, participants, Map.put(agents, "Nera", :auto_agent), events)

    assert automated.humans == []
    refute ExplorationTurns.human_due(automated)
    refute ExplorationTurns.human_after_repeat(automated, "Lyra")
    assert ExplorationTurns.brief(automated) == ""
  end

  test "absent, downed and incapacitated PCs are excluded from available recipients" do
    {world, participants, agents} = party()
    world = put_in(world.characters["Thane"].hp, 0)
    world = put_in(world.characters["Lyra"].conditions, ["stunned"])
    world = %{world | absent_characters: %{"Nera" => "En otra sala"}}
    context = ExplorationTurns.context(world, participants, agents, [turn("Vex"), turn("dm")])
    assert context.humans == []
    assert context.ai == ["Vex"]
    refute ExplorationTurns.human_due(context)

    {:ok, world} = World.return_to_scene("Nera").(world)
    context = ExplorationTurns.context(world, participants, agents, [turn("Vex"), turn("dm")])
    assert context.humans == ["Nera"]
    assert ExplorationTurns.human_due(context) == "Nera"
  end

  test "any combat turn bounds the exploration window, including a reaction" do
    {world, participants, agents} = party()
    old = [turn("Thane"), turn("Lyra"), turn("Vex")]

    for kind <- ["main", "reaction"] do
      events = old ++ [turn("dm", "combat", kind), turn("dm")]
      context = ExplorationTurns.context(world, participants, agents, events)
      assert context.ai_acted == []
      refute ExplorationTurns.human_due(context)
    end

    refute ExplorationTurns.context(%{world | phase: :combat}, participants, agents, old)
  end

  test "human order follows actual least recent participation, with deterministic ties" do
    {world, participants, agents} = party()
    events = Enum.map(["Thane", "Nera", "Thane", "Lyra", "Vex", "dm"], &turn/1)
    context = ExplorationTurns.context(world, participants, agents, events)
    assert context.humans == ["Nera", "Thane"]
    assert ExplorationTurns.human_due(context) == "Nera"
    empty = ExplorationTurns.context(world, participants, agents, [])
    assert empty.humans == ["Nera", "Thane"]
  end

  test "the first manual decision follows scene presentation before any companion turn" do
    {world, participants, agents} = party()

    for events <- [[], [turn("dm")], List.duplicate(turn("dm"), 5)] do
      context = ExplorationTurns.context(world, participants, agents, events)
      assert ExplorationTurns.opening_human(context) == "Nera"
    end

    auto = Map.merge(agents, %{"Thane" => :agent, "Nera" => :agent})
    refute ExplorationTurns.opening_human(ExplorationTurns.context(world, participants, auto, []))
    refute ExplorationTurns.opening_human(ExplorationTurns.context(world, participants, %{}, []))
  end

  test "a prior PC turn including combat or reaction means this is no longer the opening" do
    {world, participants, agents} = party()

    for actor <- ["Thane", "Lyra"],
        phase <- ["exploration", "combat"],
        kind <- ["main", "reaction"] do
      context =
        ExplorationTurns.context(world, participants, agents, [
          turn(actor, phase, kind),
          turn("dm")
        ])

      refute ExplorationTurns.opening_human(context)
    end
  end

  test "a DM self-repeat yields to an eligible manual player even before companion turns" do
    {world, participants, agents} = party()
    context = ExplorationTurns.context(world, participants, agents, [turn("Thane"), turn("dm")])
    assert context.ai_acted == []
    assert ExplorationTurns.human_after_repeat(context, "dm") == "Nera"
    refute ExplorationTurns.human_after_repeat(context, "Vex")

    no_ai = ExplorationTurns.context(world, participants, %{}, [turn("Thane"), turn("dm")])
    assert ExplorationTurns.human_after_repeat(no_ai, "dm") == "Nera"

    auto = Map.merge(agents, %{"Thane" => :agent, "Nera" => :agent})

    refute ExplorationTurns.human_after_repeat(
             ExplorationTurns.context(world, participants, auto, []),
             "dm"
           )
  end
end
