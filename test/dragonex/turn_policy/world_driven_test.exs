defmodule Dragonex.TurnPolicy.WorldDrivenTest do
  @moduledoc """
  The turn policy in isolation: feed it worlds and rosters, assert it sequences
    * round-robin in exploration,
    * along the World's initiative order in combat (one beat per monster, DM controller),
    * resetting the cursor on a phase change.
  No Session, no agents.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Character, TurnPolicy.WorldDriven, World}

  defp pc(name), do: Character.new(name: name, class: "fighter", hp: 12, max_hp: 12, side: "pc")
  defp foe(name), do: Character.new(name: name, class: "monster", hp: 7, max_hp: 7, side: "enemy")

  defp state(participants), do: WorldDriven.init(participants: Enum.map(participants, &p/1))
  defp p(id), do: %ExAgent.Session.Participant{id: id, kind: :agent}

  defp ctx(%World{} = w), do: %{shared_state: w, participants: []}

  defp turn(state, w) do
    case WorldDriven.next_participant(state, ctx(w)) do
      {:ok, id, new_state} -> {id, new_state}
      {:done, new_state} -> {nil, new_state}
    end
  end

  describe "exploration" do
    test "round-robins over the participants" do
      s = state(["dm", "fighter"])
      w = World.new()
      {id1, s} = turn(s, w)
      {id2, s} = turn(s, w)
      {id3, _} = turn(s, w)
      assert id1 == "dm"
      assert id2 == "fighter"
      assert id3 == "dm"
    end
  end

  describe "combat" do
    setup do
      w =
        World.new()
        |> then_add(World.add_character(pc("Vex")))
        |> then_add(World.add_character(foe("goblin")))
        |> then_add(World.begin_combat(["goblin", "Vex"]))

      {:ok, world: w}
    end

    test "follows initiative_order, mapping the goblin onto the DM", %{world: w} do
      # order [goblin, Vex] -> participants [dm, Vex]
      s = state(["dm", "Vex"])
      {id1, s} = turn(s, w)
      {id2, s} = turn(s, w)
      {id3, _} = turn(s, w)
      assert id1 == "dm"
      assert id2 == "Vex"
      assert id3 == "dm"
    end

    test "only the current participant may act", %{world: w} do
      s = state(["dm", "Vex"])
      {current, s} = turn(s, w)
      assert WorldDriven.can_act?(s, current, ctx(w)) == true
      other = if current == "dm", do: "Vex", else: "dm"
      refute WorldDriven.can_act?(s, other, ctx(w))
    end

    test "three consecutive monsters yield three DM beats then the PC" do
      w =
        World.new()
        |> then_add(World.add_character(pc("Vex")))
        |> then_add(World.add_character(foe("g1")))
        |> then_add(World.add_character(foe("g2")))
        |> then_add(World.add_character(foe("g3")))
        |> then_add(World.begin_combat(["g1", "g2", "g3", "Vex"]))

      s = state(["dm", "Vex"])
      {id1, s} = turn(s, w)
      {id2, s} = turn(s, w)
      {id3, s} = turn(s, w)
      {id4, s} = turn(s, w)
      {id5, _} = turn(s, w)

      assert [id1, id2, id3, id4, id5] == ["dm", "dm", "dm", "Vex", "dm"]
    end

    test "a phase change to combat resets the cursor", %{world: combat} do
      # First a couple of exploration turns build up the index...
      exploration = World.new()
      s = state(["dm", "Vex"])
      {_id, s} = turn(s, exploration)
      {_id, s} = turn(s, exploration)
      # ...then the DM triggers combat: next pick should be initiative[0] (-> dm).
      {id, _} = turn(s, combat)
      assert id == "dm"
    end
  end

  # helpers
  defp then_add(world, change) do
    assert {:ok, w} = change.(world)
    w
  end
end
