defmodule DragonexWeb.GameChatBlocksTest do
  use ExUnit.Case, async: true
  alias DragonexWeb.GameLive.Chat

  defp event(seq, type, actor, payload, visible_to \\ "all"),
    do: %{seq: seq, type: type, actor: actor, visible_to: visible_to, payload: payload}

  defp turn(seq, actor, extra \\ %{}),
    do:
      event(
        seq,
        :turn,
        actor,
        Map.merge(%{"kind" => "start", "turn_id" => "t#{seq}", "phase" => "combat"}, extra)
      )

  defp handoff(seq, to),
    do:
      event(seq, :system, "turnmaster", %{
        "kind" => "give_turn_to",
        "note" => "El turno pasa a #{to}."
      })

  defp roll(seq, who), do: event(seq, :dice, "dm", %{"who" => who, "kind" => "attack"})

  defp labels(blocks),
    do: Enum.map(blocks, &(&1.header && Chat.header_label(&1.header, "Thane", false)))

  test "a DM combat turn is headed by the acting creature" do
    events = [turn(1, "dm", %{"combatant" => "goblin2"}), roll(2, "goblin2")]
    assert labels(Chat.blocks(events, "Thane")) == ["Turno de goblin2"]
  end

  test "turns saved before the combatant field are named by their only roller" do
    events = [
      turn(1, "dm"),
      roll(2, "goblin1"),
      turn(3, "dm"),
      roll(4, "goblin1"),
      roll(5, "goblin2"),
      turn(6, "dm", %{"phase" => "exploration"}),
      roll(7, "goblin1")
    ]

    assert labels(Chat.blocks(events, "Thane")) == [
             "Turno de goblin1",
             "Turno del DM",
             "Turno del DM"
           ]
  end

  test "only the latest turn handoff stays in the chronicle" do
    events = [
      turn(1, "dm"),
      event(2, :narration, "dm", %{"text" => "El goblin cae."}),
      handoff(3, "Thane"),
      turn(4, "Thane"),
      event(5, :narration, "Thane", %{"text" => "Avanzo."}),
      handoff(6, "Lyra")
    ]

    texts =
      events
      |> Chat.blocks("Thane")
      |> Enum.flat_map(& &1.events)
      |> Enum.map(& &1.text)

    assert "El turno pasa a Lyra." in texts
    refute "El turno pasa a Thane." in texts
  end

  test "system lines keep their kind for the table" do
    events = [event(1, :system, "system", %{"kind" => "turn_retained", "note" => "En pausa."})]

    assert [%{events: [%{kind: "turn_retained", text: "En pausa."}]}] =
             Chat.blocks(events, "Thane")
  end

  test "a damage roll carries the HP it left behind" do
    damage = %{"who" => "goblin2", "kind" => "damage", "hp" => [["suso", 4, 10]]}
    events = [turn(1, "dm"), event(2, :dice, "dm", damage), roll(3, "goblin2")]

    assert [%{events: [%{consequence: "suso queda a 4/10 PG"}, %{consequence: ""}]}] =
             Chat.blocks(events, "Thane")
  end
end
