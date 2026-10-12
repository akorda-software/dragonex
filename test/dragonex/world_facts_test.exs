defmodule Dragonex.WorldFactsTest do
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

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Games, Game, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "establish_fact persists a durable fact the DM can read back" do
    {:ok, game} =
      Games.create_game(
        title: "facts",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}]
      )

    # The DM records a concrete hook on its first beat.
    script = [
      tool_calls([
        call("establish_fact", %{
          "fact" =>
            "Un mensajero del Concejo entregó a Thane un pergamino con una misión en Thornwood"
        })
      ]),
      narration("Un mensajero cruza la taberna y entrega un pergamino a Thane.")
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [model: %Test{script: script}, scene_model: scene_model(), roller: fn _ -> 10 end]}}
      )

    wait(pid)

    facts = Game.world(pid).facts
    assert Enum.any?(facts, &String.contains?(&1, "mensajero del Concejo"))
    assert Games.load_world(Games.get_game(game.id)).facts == facts
    refute_failed_turn(game.id)
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

  test "add_fact caps the list to the most recent facts" do
    # Build 35 facts by repeatedly applying add_fact. Only the last 30 survive.
    w =
      Enum.reduce(1..35, World.new(), fn n, world ->
        {:ok, w} = World.add_fact("hecho #{n}").(world)
        w
      end)

    assert length(w.facts) == 30
    # Oldest facts dropped, most recent kept.
    refute "hecho 1" in w.facts
    refute "hecho 5" in w.facts
    assert "hecho 6" in w.facts
    assert "hecho 35" in w.facts
    assert hd(w.facts) == "hecho 6"
    assert List.last(w.facts) == "hecho 35"
  end

  test "establish_fact scrubs model text before persisting (D7)" do
    {:ok, game} =
      Games.create_game(
        title: "scrub",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}]
      )

    # The DM records a fact that leaks an HP stat ("3/7 pg") — the kind of inline
    # stat Text.scrub is built to strip. Without scrubbing at the tool boundary,
    # this tainted text would persist and be echoed to every agent every turn.
    script = [
      tool_calls([
        call("establish_fact", %{
          "fact" => "La taberna tiene una puerta oculta. El goblin jefe queda en 3/7 pg."
        })
      ]),
      narration("Thane encuentra una puerta.")
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [model: %Test{script: script}, scene_model: scene_model(), roller: fn _ -> 10 end]}}
      )

    wait(pid)

    facts = Game.world(pid).facts

    # The durable part survives...
    assert Enum.any?(facts, &String.contains?(&1, "puerta oculta"))
    # ...but the leaked stat was scrubbed before reaching the world.
    refute Enum.any?(facts, &String.contains?(&1, "3/7"))
    assert Games.load_world(Games.get_game(game.id)).facts == facts
    refute_failed_turn(game.id)
  end

  test "set_scene scrubs model text before persisting (D7)" do
    {:ok, game} =
      Games.create_game(
        title: "scene-scrub",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}]
      )

    script = [
      tool_calls([
        call("set_scene", %{
          "narration" =>
            "La taberna queda en silencio. El goblin jefe queda en 3/7 pg tras la pelea."
        })
      ]),
      narration("La taberna queda en silencio.")
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [model: %Test{script: script}, scene_model: scene_model(), roller: fn _ -> 10 end]}}
      )

    wait(pid)

    # The scene was overwritten with scrubbed text — the leaked stat is gone.
    refute String.contains?(Game.world(pid).scene || "", "3/7")
    assert Game.world(pid).scene =~ "La taberna queda en silencio."
    assert Game.world(pid).scene != game.world["scene"]
    assert Games.load_world(Games.get_game(game.id)).scene == Game.world(pid).scene
    refute_failed_turn(game.id)
  end

  defp scene_model do
    %Test{
      script: [
        tool_calls([
          call("final_result", %{
            "scene" => "La taberna sigue tranquila, con luz en el mostrador."
          })
        ])
      ]
    }
  end

  defp wait(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  defp refute_failed_turn(game_id) do
    refute Enum.any?(
             Games.list_events(game_id),
             &String.contains?(&1.payload["note"] || "", "el turno falló")
           )
  end

  test "creating a game from a bible seeds NPC facts" do
    bible = Dragonex.Scenarios.bible(Dragonex.Scenarios.get("tavern"))

    {:ok, game} =
      Games.create_game(
        title: "biblia",
        scene: "una taberna",
        story_bible: bible,
        roster: [{Archetypes.fighter(), :human}]
      )

    facts = Dragonex.Codec.decode(game.world).facts
    assert Enum.any?(facts, &(&1 =~ "Borin"))
    assert Enum.any?(facts, &(&1 =~ "posadero"))
    assert Enum.any?(facts, &(&1 =~ "asaltos goblin"))
    refute Enum.any?(facts, &(&1 =~ "Grimm"))
  end

  test "seed_facts parses tavern NPCs" do
    facts =
      Dragonex.Scenarios.seed_facts(Dragonex.Scenarios.bible(Dragonex.Scenarios.get("tavern")))

    assert "El posadero se llama Borin." in facts
    assert "La guardia se llama Sable." in facts
    assert Enum.any?(facts, &(&1 =~ "asaltos goblin"))
    assert Enum.any?(facts, &(&1 =~ "Los enemigos previstos son: goblin, wolf."))
  end
end
