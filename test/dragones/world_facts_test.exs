defmodule Dragones.WorldFactsTest do
  @moduledoc """
  Bug — DM apila ganchos y los abandona. The partida introduces a hook
  (mensajero, puerta secreta, encargo) in narration, but narration lives in the
  truncated shared history, so a few turns later the DM re-introduces or
  contradicts it.

  Fix: `world.facts` (durable) + the `establish_fact` tool + a "Hechos
  establecidos" block in every agent's `world_brief`. Facts survive truncation
  and are read by all agents every turn, so the partida's concrete state stays
  consistent.
  """

  use ExUnit.Case, async: false

  import Dragones.Test.Harness

  alias Dragones.{Archetypes, Games, Game, World}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})
    :ok
  end

  test "establish_fact persists a durable fact the DM can read back" do
    {:ok, game} =
      Games.create_game(
        title: "facts",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # The DM records a concrete hook on its first beat.
    script = [
      tool_calls([
        call("establish_fact", %{
          "fact" =>
            "Un mensajero del Concejo entregó a Thane un pergamino con una misión en Thornwood"
        })
      ]),
      text("Un mensajero cruza la taberna y entrega un pergamino a Thane.")
    ]

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Dragones.Game, {game.id, [model: %Test{script: script}, roller: fn _ -> 10 end]}}
      )

    # Wait until the DM beat (and its tool call) has run.
    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Game.world(pid).facts != []
               end,
               5_000
             )

    facts = Game.world(pid).facts
    assert Enum.any?(facts, &String.contains?(&1, "mensajero del Concejo"))
  end

  test "World.add_fact is idempotent and trims whitespace" do
    w = World.new()

    {:ok, w1} = World.add_fact("  Un hecho  ").(w)
    assert w1.facts == ["Un hecho"]

    # Adding the same fact again is a no-op.
    {:ok, w2} = World.add_fact("Un hecho").(w1)
    assert w2.facts == ["Un hecho"]

    # Empty facts are ignored.
    {:ok, w3} = World.add_fact("   ").(w2)
    assert w3.facts == ["Un hecho"]
  end
end
