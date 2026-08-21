defmodule Dragonex.TurnMasterLoopTest do
  @moduledoc """
  Fase B/C — TurnMaster integrated in the Game loop: handoff, WorldDriven
  fallback, mini-turns, acted_this_round.
  """

  use ExUnit.Case, async: false

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Codec, Games, Game, Monsters, World}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragonex.Repo, {:shared, self()})
    :ok
  end

  defp hit_roller do
    fn
      20 -> 15
      _n -> 1
    end
  end

  # DM narrates once; TurnMaster hands to Thane then back to dm.
  defp dm_script do
    [
      text("El DM sitúa la escena en la ruina."),
      tool_calls([
        call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})
      ]),
      text("El goblin ataca."),
      text("El DM cierra.")
    ]
  end

  defp tm_script_give(to) do
    [
      tool_calls([call("give_turn_to", %{"participant" => to})]),
      text("ok")
    ]
  end

  defp waiting_on(name),
    do: fn s -> s.status == :waiting and s.current == name end

  test "TurnMaster give_turn_to hands the floor to a human PC" do
    {:ok, game} =
      Games.create_game(
        title: "tm handoff",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    # Script: TM → dm, DM narrates, TM → Thane (waiting).
    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("dm")
      }

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [model: %Test{script: dm_script()}, turnmaster_model: tm, roller: hit_roller()]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)

    events = Games.list_events(game.id)
    tm_notes = Enum.filter(events, &(&1.actor == "turnmaster" and &1.type == :system))
    assert Enum.any?(tm_notes, fn e -> (e.payload["note"] || "") =~ "Thane" end)
  end

  test "missing TurnMaster decision falls back to WorldDriven without pausing" do
    {:ok, game} =
      Games.create_game(
        title: "tm fallback",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    # Empty TM model → no tool-call → fallback every time.
    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: dm_script()},
            turnmaster_model: %Test{label: "(no decision)"},
            roller: hit_roller()
          ]}}
      )

    # With goblin-first initiative + WorldDriven fallback, DM (goblin) acts then
    # Thane waits — same as pre-TurnMaster behaviour.
    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)

    events = Games.list_events(game.id)

    assert Enum.any?(events, fn e ->
             e.type == :system and (e.payload["note"] || "") =~ "relevo"
           end)

    # Soft fallback must not trip the pause circuit.
    assert Game.status(pid) in [:waiting, :running]
  end

  test "acted_this_round codec round-trip" do
    w =
      World.new(
        phase: :combat,
        initiative_order: ["Thane", "goblin"],
        acted_this_round: MapSet.new(["Thane"])
      )

    encoded = Codec.encode(w)
    assert encoded["acted_this_round"] == ["Thane"]

    decoded = Codec.decode(encoded)
    assert MapSet.member?(decoded.acted_this_round, "Thane")
  end

  test "mark_acted and round_complete?" do
    world =
      World.new()
      |> then(fn w -> elem(World.add_character(Archetypes.fighter()).(w), 1) end)
      |> then(fn w -> elem(World.add_character(Monsters.goblin()).(w), 1) end)

    {:ok, combat} = World.begin_combat(["Thane", "goblin"]).(world)
    assert MapSet.size(combat.acted_this_round) == 0

    {:ok, marked} = World.mark_acted("Thane").(combat)
    assert MapSet.member?(marked.acted_this_round, "Thane")
    refute World.round_complete?(marked, ["Thane", "goblin"])

    {:ok, full} = World.mark_acted("goblin").(marked)
    # cycle is participant ids; both names in cycle
    assert World.round_complete?(full, ["Thane", "goblin"])

    {:ok, next} = World.next_round().(full)
    assert MapSet.size(next.acted_this_round) == 0
    assert next.round == combat.round + 1
  end

  test "cut_in records mini-turn decision without requiring Game mutation from tools" do
    alias Dragonex.TurnMaster.{Decision, Tools}

    world =
      World.new()
      |> then(fn w -> elem(World.add_character(Archetypes.fighter()).(w), 1) end)
      |> then(fn w -> elem(World.add_character(Monsters.goblin()).(w), 1) end)

    {:ok, combat} = World.begin_combat(["Thane", "goblin"]).(world)
    {:ok, rec} = Decision.start()

    assert {:ok, _} =
             Tools.cut_in(
               %{deps: %{decision: rec, world: combat, participants: ["Thane", "dm"]}},
               "Thane"
             )

    assert Decision.get(rec) == %{action: :cut_in, to: "Thane"}
    # World untouched
    assert combat.acted_this_round == MapSet.new()
    Decision.stop(rec)
  end

  test "scripted cut_in mini-turn then returns via give_turn_to" do
    {:ok, game} =
      Games.create_game(
        title: "tm cut_in",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    tm =
      %Test{
        # After Thane's mini-turn, hand back to dm
        script:
          tm_script_give("dm") ++
            [
              tool_calls([call("cut_in", %{"participant" => "Thane"})]),
              text("ok")
            ] ++
            tm_script_give("dm") ++
            tm_script_give("Thane")
      }

    human_attack = [
      tool_calls([
        call("make_attack", %{
          "attacker" => "Thane",
          "target" => "goblin",
          "weapon" => "longsword"
        })
      ]),
      text("Thane intercepta.")
    ]

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: dm_script() ++ human_attack ++ dm_script()},
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
      )

    # Eventually Thane should get a waiting turn (main or after mini).
    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 s.current == "Thane" and s.status in [:waiting, :running]
               end,
               15_000
             )

    events = Games.list_events(game.id)

    assert Enum.any?(events, fn e ->
             e.actor == "turnmaster" and
               (e.payload["kind"] == "cut_in" or e.payload["kind"] == :cut_in or
                  (e.payload["note"] || "") =~ "interrumpe")
           end)
  end
end
