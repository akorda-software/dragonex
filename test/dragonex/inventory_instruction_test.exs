defmodule Dragonex.InventoryInstructionTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Game.Instructions, World}

  defp event(seq, type, actor, audience, text),
    do: %{seq: seq, type: type, actor: actor, visible_to: audience, payload: %{"text" => text}}

  test "the DM receives only an unresolved action visible to its role" do
    world = World.new()
    action = event(2, :action, "Mara", "all", "Dejo el botón sobre el pretil.")
    events = [event(1, :narration, "dm", "all", "El cruce está despejado."), action]

    assert Instructions.inventory_instruction(world, "dm", events) =~
             "Mara: Dejo el botón sobre el pretil."

    closed = events ++ [event(3, :narration, "dm", "all", "El botón queda sobre la piedra.")]
    refute Instructions.inventory_instruction(world, "dm", closed) =~ action.payload["text"]
    private = [%{action | visible_to: "Lyra"}]
    refute Instructions.inventory_instruction(world, "dm", private) =~ action.payload["text"]
    refute Instructions.inventory_instruction(world, "Mara", events) =~ action.payload["text"]
    assert Instructions.inventory_instruction(%{world | phase: :combat}, "dm", events) == ""
  end

  test "declaration context is bounded and scrubbed without interpreting an item or quantity" do
    text = "Mara: Dejo el botón. " <> String.duplicate("x", 3000)
    action = event(1, :action, "Mara", "all", text)
    instruction = Instructions.inventory_instruction(World.new(), "dm", [action])

    [_, declaration] =
      String.split(
        instruction,
        "Última declaración pendiente de consecuencias del mundo — Mara: "
      )

    assert String.length(declaration) <= 1800
    assert declaration =~ "Dejo el botón."
    refute declaration =~ "Mara:"
  end
end
