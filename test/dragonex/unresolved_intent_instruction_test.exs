defmodule Dragonex.UnresolvedIntentInstructionTest do
  use ExUnit.Case, async: true

  alias Dragonex.Game.Instructions
  alias Dragonex.Games.GameEvent

  defp turn(seq, actor, id),
    do: %GameEvent{
      seq: seq,
      type: :turn,
      actor: actor,
      payload: %{"kind" => "start", "turn_id" => id}
    }

  defp voice(seq, actor, id, text),
    do: %GameEvent{
      seq: seq,
      type: :narration,
      actor: actor,
      payload: %{
        "text" => text,
        "turn_id" => id,
        "kind" => "human_declaration",
        "complete" => true
      }
    }

  defp dice(seq, id),
    do: %GameEvent{seq: seq, type: :dice, actor: "Thane", payload: %{"turn_id" => id}}

  defp note(seq),
    do: %GameEvent{
      seq: seq,
      type: :system,
      actor: "turnmaster",
      payload: %{"note" => "El turno pasa al DM."}
    }

  @attack "Entro y ataco a la rata más cercana."

  # 19451/31–38: the DM narrated Thane's miss although no attack was rolled.
  test "a human declaration that applied no rules is flagged as pending for the DM" do
    events = [
      turn(26, "Thane", "t"),
      voice(31, "Thane", "t", @attack),
      note(32),
      turn(33, "dm", "d")
    ]

    hint = Instructions.unresolved_human_intent(events)
    assert hint =~ "La declaración de Thane no aplicó reglas ni tiradas"
    assert hint =~ "no narres su resultado como ocurrido"
    assert hint =~ @attack
  end

  test "a rolled declaration, an older human turn or another actor in between give no hint" do
    rolled = [
      turn(1, "Thane", "t"),
      dice(2, "t"),
      voice(3, "Thane", "t", @attack),
      turn(4, "dm", "d")
    ]

    assert Instructions.unresolved_human_intent(rolled) == ""

    bot_between = [
      turn(1, "Thane", "t"),
      voice(2, "Thane", "t", @attack),
      turn(3, "Lyra", "l"),
      turn(4, "dm", "d")
    ]

    assert Instructions.unresolved_human_intent(bot_between) == ""
    assert Instructions.unresolved_human_intent([turn(1, "dm", "d")]) == ""
  end
end
