defmodule Dragonex.Flows.RestClockTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, World, Tools}
  alias ExAgent.{Server, Session}

  test "TestModel uses party rest, game time and explicit hit dice through the tools" do
    a = Character.new(name: "A", class: "fighter", level: 3, hp: 1, max_hp: 30)
    b = Character.new(name: "B", hp: 1, max_hp: 12)
    w = World.new(characters: %{"A" => a, "B" => b})
    session = start_session(world: w, policy: :round_robin, participants: [p("dm"), p("A")])
    assert {:ok, "dm"} = Session.start(session)

    agent =
      start_dm(
        id: "rest-clock-#{System.unique_integer([:positive])}",
        script: [
          tool_calls([call("rest_party", %{"targets" => ["A", "B"], "kind" => "long"})]),
          tool_calls([call("advance_time", %{"seconds" => 86400})]),
          tool_calls([call("short_rest", %{"target" => "A", "hit_dice" => 2})]),
          tool_calls([call("short_rest", %{"target" => "B"})]),
          text("Descanso resuelto.")
        ]
      )

    assert {:ok, _} =
             Server.chat(agent, "descansa", deps: deps_for(session, "dm", fixed_roller(4)))

    final = Session.read_state(session)
    assert final.elapsed_seconds == 28800 + 86400 + 7200
    assert final.characters["A"].hp == 30
    assert final.characters["B"].hp == 12
    assert final.rest_state["A"]["hit_dice_used"] == 2
    assert final.rest_state["B"]["hit_dice_used"] == 1
    pc = %{deps: deps_for(session, "A", fixed_roller(4))}
    assert {:error, _} = Tools.advance_time(pc, 86400)
    assert {:error, _} = Tools.rest_party(pc, ["A", "B"], "long")
  end
end
