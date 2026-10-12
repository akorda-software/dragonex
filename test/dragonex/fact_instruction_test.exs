defmodule Dragonex.FactInstructionTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Game.Instructions, World}

  test "exploration guidance separates a proposed discovery, canonical facts and NPC testimony" do
    world = World.new()
    guidance = Instructions.fact_instruction(world, "dm")
    assert guidance =~ "MEMORIA DE DESCUBRIMIENTOS"
    assert guidance =~ "narrador humano"
    assert guidance =~ "establish_fact"
    assert guidance =~ "set_scene"
    assert guidance =~ "record_npc_statement"
    assert guidance =~ "no demuestra"
    assert guidance =~ "No dupliques"
    assert Instructions.fact_instruction(%{world | phase: :combat}, "dm") == ""
  end

  test "human and AI resolution leave canonical world confirmation to the DM" do
    for actor <- ["Mara", "Lyra", "Vex"] do
      guidance = Instructions.fact_instruction(World.new(), actor)
      assert guidance =~ "turno de #{actor}"
      assert guidance =~ "motor las rechaza"
      assert guidance =~ "posterior turno DM"
      assert guidance =~ "set_scene"
      refute guidance =~ "MEMORIA DE DESCUBRIMIENTOS"
    end
  end
end
