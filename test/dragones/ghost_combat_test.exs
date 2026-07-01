defmodule Dragones.GhostCombatTest do
  @moduledoc """
  Bug #2 — ghost combat. The DM narrates/spawns a hostile entering the scene but
  never calls roll_initiative, so the loop stalls in exploration while everyone
  roleplays a fight that isn't sequenced (the DM re-narrates "aparece un esqueleto"
  for several turns before initiative finally fires).

  Fix: `Dragones.Game.maybe_force_combat/2` compares living enemies before/after
  each beat and, when a beat INTRODUCES a hostile while still in exploration,
  rolls initiative itself. Comparing before/after — rather than acting on the
  mere presence of enemies — avoids false positives at partida start, where the
  scene-setting beat may legitimately have monsters already in the world.
  """

  use ExUnit.Case, async: false

  import Dragones.Test.Harness

  alias Dragones.{Archetypes, Games, Game}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})
    :ok
  end

  # A roller that pops from a shared queue — survives cross-process tool calls
  # (tools run inside the agent's Server, not the test process).
  defp seq_roller(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn _sides ->
      Agent.get_and_update(agent, fn
        [h | t] -> {h, t}
        [] -> raise "seq_roller exhausted"
      end)
    end
  end

  # An exploration partida with one human fighter and NO starting monsters.
  defp new_exploration_game do
    {:ok, game} =
      Games.create_game(
        title: "ghost",
        scene: "una cueva oscura",
        roster: [{Archetypes.fighter(), :human}]
      )

    assert Games.load_world(game).phase == :exploration
    game
  end

  test "spawning a monster in exploration forces combat automatically" do
    game = new_exploration_game()

    # The DM spawns a goblin but NEVER calls roll_initiative — exactly the ghost
    # combat pattern. The engine must take initiative itself.
    script = [
      tool_calls([call("spawn_monster", %{"kind" => "goblin", "name" => "goblin"})]),
      text("Un goblin salta de las sombras, chirriando.")
    ]

    # Initiative rolls: Thane 20 (wins), goblin 1 -> Thane first, so the loop
    # settles on Thane's :waiting turn and the await has a stable predicate.
    roller = seq_roller([20, 1])

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Dragones.Game, {game.id, [model: %Test{script: script}, roller: roller]}}
      )

    assert :ok == Game.await(pid, fn s -> s.status == :waiting end, 5_000)

    world = Game.world(pid)
    assert world.phase == :combat, "combat should be forced after a hostile spawns in exploration"
    assert "goblin" in world.initiative_order
    assert "Thane" in world.initiative_order

    # A system event documents the engine-driven initiative.
    events = Games.list_events(game.id)

    assert Enum.any?(
             events,
             fn e -> e.type == :system and (e.payload["note"] || "") =~ "toma la iniciativa" end
           )
  end

  test "a partida that already has monsters in exploration is NOT auto-forced" do
    # A roster WITH a goblin, opening in exploration (no initiative baked in).
    {:ok, game} =
      Games.create_game(
        title: "ghost",
        scene: "una clariana",
        roster: [{Archetypes.fighter(), :human}, {Dragones.Monsters.goblin(), :ai}]
      )

    # The DM just narrates the scene on its beats — no spawn, no new enemy.
    # The goblin (AI) also just responds with text; nobody spawns, so the engine
    # must keep the partida in exploration.
    script = [text("El goblin os observa desde la maleza, sin moverse todavía.")]

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Dragones.Game, {game.id, [model: %Test{script: script}, roller: fn _ -> 10 end]}}
      )

    # Wait until the human (Thane) is waiting — by then the DM (and possibly the
    # goblin) have taken their exploration beats without forcing combat.
    assert :ok == Game.await(pid, fn s -> s.status == :waiting end, 5_000)

    world = Game.world(pid)

    assert world.phase == :exploration,
           "pre-existing enemies must NOT auto-trigger combat — only newly introduced ones"

    events = Games.list_events(game.id)

    refute Enum.any?(
             events,
             fn e -> e.type == :system and (e.payload["note"] || "") =~ "toma la iniciativa" end
           )
  end
end
