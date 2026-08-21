defmodule Dragonex.Flows.DiceTest do
  @moduledoc """
  Flow 4 — dice.

  The tools never roll directly; they call `ctx.deps.roller.(sides)`, so a test
  injects a fixed roller while production passes `&Dragonex.Dice.roll/1`. This
  validates the deps-forwarding path of the loop with a real (if trivial) game
  need: randomness that is testable.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  test "the roll tool reports the injected value to the model" do
    dm =
      start_dm(
        id: "dm-dice",
        script: [
          tool_calls([call("roll", %{"sides" => 20})]),
          text("natural 20!")
        ]
      )

    game = start_session(policy: :round_robin, participants: [p("dm", :agent, dm)])
    assert {:ok, "dm"} = ExAgent.Session.start(game)

    # The model is told the roller returned 20 (deterministic for the test).
    assert :ok = take_turn(game, "dm", dm, fixed_roller(20))
  end

  test "advantage keeps the higher of two rolls" do
    roller = Dragonex.Dice.always(15)
    {kept, a, b} = Dragonex.Dice.roll_advantage(20, :advantage, roller)
    assert kept == 15 and a == 15 and b == 15

    # With a low+high roller, advantage keeps the high.
    {kept, _, _} = Dragonex.Dice.roll_advantage(20, :advantage, cycling([4, 18]))
    assert kept == 18
  end

  test "disadvantage keeps the lower of two rolls" do
    {kept, _, _} = Dragonex.Dice.roll_advantage(20, :disadvantage, cycling([4, 18]))
    assert kept == 4
  end

  test "dice expressions (2d6+3) parse and sum" do
    # All sixes: 2*6 + 3 = 15
    assert Dragonex.Dice.roll_expr("2d6+3", Dragonex.Dice.always(6)) == 15
    # 1d20 with no mod, always 11
    assert Dragonex.Dice.roll_expr("1d20", Dragonex.Dice.always(11)) == 11
    # subtraction
    assert Dragonex.Dice.roll_expr("1d8-2", Dragonex.Dice.always(5)) == 3
  end

  # A roller that cycles through a fixed list (a closure over an Agent box).
  defp cycling(values) do
    {:ok, box} = Agent.start_link(fn -> values end)

    fn _sides ->
      Agent.get_and_update(box, fn
        [h | t] -> {h, t ++ [h]}
        [] -> {1, []}
      end)
    end
  end
end
