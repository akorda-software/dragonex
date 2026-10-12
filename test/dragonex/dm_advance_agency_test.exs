defmodule Dragonex.DMAdvanceAgencyTest do
  use ExUnit.Case, async: true

  alias Dragonex.Game.Instructions

  test "default and stall guidance respect the style and do not order a collective relocation" do
    for prompt <- [
          Instructions.dm_instruction(),
          Instructions.dm_advance_instruction(),
          Instructions.dm_post_combat_instruction()
        ] do
      refute prompt =~ "traslada al grupo"
      refute prompt =~ "la party es trasladada"
      assert prompt =~ "Respeta el estilo de partida"
      assert prompt =~ "No decidas acciones ni traslados de los PCs"
    end
  end
end
