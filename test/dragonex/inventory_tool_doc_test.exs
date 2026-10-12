defmodule Dragonex.InventoryToolDocTest do
  use ExUnit.Case, async: true

  # 19451/77 stored «book of accounts» in a Spanish table.
  test "the DM is told to name new scene objects as narrated, in the game language" do
    tool = Enum.find(Dragonex.DM.tools(), &(&1.name == "grant_item"))

    assert tool.description =~
             "name a new scene object exactly as narrated, in the language of the game"
  end

  # 19451/86 narrated «El encargo queda cumplido» without a durable fact.
  test "a confirmed delivery that fulfils a quest is to be recorded as closed" do
    world = Dragonex.World.new()

    assert Dragonex.Game.Instructions.inventory_instruction(world, "dm") =~
             "regístralo como cerrado con establish_fact"
  end
end
