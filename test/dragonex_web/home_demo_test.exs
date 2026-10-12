defmodule DragonexWeb.HomeDemoTest do
  use ExUnit.Case, async: true
  alias DragonexWeb.HomeDemo

  test "every scripted roll sends the dice the chronicle line reports" do
    for step <- 0..(HomeDemo.length() - 1), {:rolls, rolls} = entry <- [HomeDemo.entry(step)] do
      assert %{groups: groups, authoritative: true} = HomeDemo.dice(step), inspect(entry)
      sent = for g <- groups, r <- g.rolls, do: [g.sides, r.value]
      assert Enum.sort(sent) == Enum.sort(Enum.flat_map(rolls, & &1["dice"]))
    end

    assert HomeDemo.dice(0) == nil
  end

  test "the chronicle groups lines under the table's turn headers, Thane being the visitor" do
    blocks = HomeDemo.blocks(HomeDemo.length())
    labels = Enum.map(blocks, &IO.iodata_to_binary(&1.header.label))

    assert labels == [
             "Turno del DM",
             "Turno de Vex",
             "Turno de Lyra",
             "Thane · TÚ",
             "Turno del DM",
             "Turno de Vex"
           ]

    [_dm, vex | _] = blocks
    assert [%{kind: :roll, text: attack}, %{kind: :roll}] = vex.lines
    assert attack == "ataque a rata1 con arco corto d20:16 +5 = 21 vs CA 12 → ¡ACIERTO!"
    assert List.last(List.last(blocks).lines).text == "⚔ El combate termina."
  end

  test "the opening paints the DM and the initiative, and the tray reads the latest roll" do
    assert [%{lines: [%{kind: :dm}, %{kind: :roll}, %{kind: :roll}, %{kind: :roll}]}] =
             HomeDemo.blocks(HomeDemo.opening())

    assert HomeDemo.last_roll(2) == nil
    assert %{who: "Thane", what: "iniciativa", total: 3} = HomeDemo.last_roll(HomeDemo.opening())

    assert %{who: "Vex", what: "ataque", total: 21, outcome: "¡Acierto!", tone: "dg-win"} =
             HomeDemo.last_roll(5)
  end

  test "the tray palette hides the grid under the felt" do
    palette = Jason.decode!(HomeDemo.dice_palette())
    assert palette["border"] == palette["faceEdge"]
  end
end
