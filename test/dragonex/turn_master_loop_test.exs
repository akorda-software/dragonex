defmodule Dragonex.TurnMasterLoopTest do
  @moduledoc """
  Fase B/C — TurnMaster integrated in the Game loop: handoff, WorldDriven
  fallback, mini-turns, acted_this_round.
  """

  use ExUnit.Case, async: false

  import Dragonex.Test.Harness
  import ExUnit.CaptureLog

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

  defp kill_roller do
    fn
      20 -> 15
      _n -> 6
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

  # Playtest 2026-09-16: a real LLM kept emitting valid tool calls every step
  # and never the final text — the TM beat spun to exAgent's default
  # max_steps of 50 (~50s stall, ~50 burnt calls) before the fallback. Now the
  # beat fails at 3 steps and the warning carries the last tool calls as
  # evidence (no run store survives the process).
  test "looping TM model fails fast at 3 steps with evidence; WorldDriven keeps the partida going" do
    {:ok, game} =
      Games.create_game(
        title: "tm maxsteps",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    # Valid `give_turn_to dm` calls forever — never a final text response.
    looping_tm = %Test{
      script: List.duplicate(tool_calls([call("give_turn_to", %{"participant" => "dm"})]), 12)
    }

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {Dragonex.Game,
             {game.id,
              [
                model: %Test{script: dm_script() ++ [text("ok")]},
                turnmaster_model: looping_tm,
                roller: hit_roller()
              ]}}
          )

        assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)
        # Soft fallback must not trip the pause circuit.
        assert Game.status(pid) in [:waiting, :running]
      end)

    # Failed fast at the 3-step cap…
    assert log =~ "turnmaster beat failed: {:max_steps_exceeded, 3}"
    # …and the warning names what the model actually called (PubSub evidence).
    assert log =~ "give_turn_to"
    assert log =~ ~s("participant" => "dm")

    events = Games.list_events(game.id)
    assert Enum.any?(events, fn e -> e.type == :system end)
  end

  test "mute TM at exploration start passes to the DM without relevo" do
    {:ok, game} =
      Games.create_game(
        title: "opener",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}]
      )

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: [text("El posadero limpia un vaso.")] ++ [text("ok")]},
            turnmaster_model: %Test{label: "(no decision)"}
          ]}}
      )

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e ->
                   e.type == :narration and e.actor == "dm" and
                     (e.payload["text"] || "") =~ "posadero"
                 end)
               end,
               10_000
             )

    events = Games.list_events(game.id)
    notes = Enum.map(events, &(&1.payload["note"] || ""))
    assert Enum.any?(notes, &(&1 =~ "El turno pasa al DM."))
    refute Enum.any?(notes, &(&1 =~ "relevo"))
  end

  test "after a PC in exploration the world answers without a TM beat" do
    {:ok, game} =
      Games.create_game(
        title: "mesa pass",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}]
      )

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: [text("Thane pregunta al tabernero.")] ++ [text("ok")]},
            turnmaster_model: %Test{
              script: tm_script_give("Thane") ++ tm_script_give("Lyra") ++ tm_script_give("Lyra")
            }
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, _} = Game.declare(pid, "Thane", "Pregunto al tabernero qué se cuece.")

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 notes =
                   s.events
                   |> Enum.filter(&(&1.type == :system))
                   |> Enum.map(&(&1.payload["note"] || ""))

                 Enum.any?(notes, &(&1 =~ "El turno pasa al DM."))
               end,
               10_000
             )

    events = Games.list_events(game.id)
    refute Enum.any?(events, fn e -> (e.payload["note"] || "") =~ "relevo" end)

    thane_then_dm =
      events
      |> Enum.filter(&(&1.type == :system))
      |> Enum.map(&(&1.payload["note"] || ""))
      |> Enum.filter(&(&1 =~ "El turno pasa"))

    assert Enum.any?(thane_then_dm, &(&1 =~ "al DM"))
  end

  test "after a DM question to a human the other PC does not take the floor" do
    {:ok, game} =
      Games.create_game(
        title: "dm pregunta",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :human}]
      )

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: [text("Thane, el pergamino está cerrado. ¿Lo abres?")]},
            turnmaster_model: %Test{
              script: tm_script_give("Lyra") ++ tm_script_give("Lyra") ++ tm_script_give("Lyra")
            }
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    refute Game.snapshot(pid).current == "Lyra"
  end

  test "a tú/si quieres prompt after a human keeps that human on the floor" do
    {:ok, game} =
      Games.create_game(
        title: "abrelo tu",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :human}]
      )

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{
              script:
                [text("El pergamino descansa en la mesa.")] ++
                  [text("Thane se acerca.")] ++
                  [text("Ábrelo tú, si quieres.")]
            },
            turnmaster_model: %Test{
              script:
                tm_script_give("Thane") ++
                  tm_script_give("Lyra") ++
                  tm_script_give("Lyra") ++
                  tm_script_give("Lyra")
            }
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, _} = Game.declare(pid, "Thane", "Miro el pergamino.")

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e ->
                   e.type == :narration and e.actor == "dm" and
                     (e.payload["text"] || "") =~ "si quieres"
                 end)
               end,
               10_000
             )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    refute Game.snapshot(pid).current == "Lyra"
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

  test "three monsters each get a DM beat before the PC (D34)" do
    {:ok, game} =
      Games.create_game(
        title: "d34 multi monster",
        scene: "a torchlit ruin",
        roster: [
          {Archetypes.fighter(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai},
          {Monsters.goblin(name: "g3"), :ai}
        ],
        initiative: ["g1", "g2", "g3", "Thane"]
      )

    dm_beats =
      Enum.flat_map(["g1", "g2", "g3"], fn name ->
        [
          text("El DM sitúa la escena."),
          tool_calls([
            call("make_attack", %{
              "attacker" => name,
              "target" => "Thane",
              "weapon" => "scimitar"
            })
          ]),
          text("#{name} ataca."),
          text("El DM cierra.")
        ]
      end)

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: dm_beats},
            turnmaster_model: %Test{label: "(no decision)"},
            roller: hit_roller()
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)

    snap = Game.snapshot(pid)
    assert MapSet.member?(snap.world.acted_this_round, "g1")
    assert MapSet.member?(snap.world.acted_this_round, "g2")
    assert MapSet.member?(snap.world.acted_this_round, "g3")
    refute MapSet.member?(snap.world.acted_this_round, "Thane")
    assert snap.world.current_combatant == "Thane"

    events = Games.list_events(game.id)
    dm_narr = Enum.filter(events, &(&1.actor == "dm" and &1.type == :narration))
    assert length(dm_narr) >= 3
  end

  test "TurnMaster give_turn_to each monster then the PC (D34)" do
    {:ok, game} =
      Games.create_game(
        title: "d34 tm named",
        scene: "a torchlit ruin",
        roster: [
          {Archetypes.fighter(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai},
          {Monsters.goblin(name: "g3"), :ai}
        ],
        initiative: ["g1", "g2", "g3", "Thane"]
      )

    dm_beats =
      Enum.flat_map(["g1", "g2", "g3"], fn name ->
        [
          text("El DM sitúa la escena."),
          tool_calls([
            call("make_attack", %{
              "attacker" => name,
              "target" => "Thane",
              "weapon" => "scimitar"
            })
          ]),
          text("#{name} ataca."),
          text("El DM cierra.")
        ]
      end)

    tm =
      %Test{
        script:
          tm_script_give("g1") ++
            tm_script_give("g2") ++
            tm_script_give("g3") ++
            tm_script_give("Thane")
      }

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id, [model: %Test{script: dm_beats}, turnmaster_model: tm, roller: hit_roller()]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)

    snap = Game.snapshot(pid)
    assert MapSet.member?(snap.world.acted_this_round, "g1")
    assert MapSet.member?(snap.world.acted_this_round, "g2")
    assert MapSet.member?(snap.world.acted_this_round, "g3")
    assert snap.world.current_combatant == "Thane"

    events = Games.list_events(game.id)
    tm_notes = Enum.filter(events, &(&1.actor == "turnmaster" and &1.type == :system))
    notes = Enum.map(tm_notes, &(&1.payload["note"] || ""))
    assert Enum.any?(notes, &(&1 =~ "g1"))
    assert Enum.any?(notes, &(&1 =~ "g2"))
    assert Enum.any?(notes, &(&1 =~ "g3"))
  end

  test "mid-round monster death skips the fallen and still beats remaining slots (D34)" do
    {:ok, game} =
      Games.create_game(
        title: "d34 mid-round death",
        scene: "a torchlit ruin",
        roster: [
          {Archetypes.fighter(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai},
          {Monsters.goblin(name: "g3"), :ai}
        ],
        initiative: ["g1", "g2", "g3", "Thane"]
      )

    dm_beats = [
      tool_calls([
        call("make_attack", %{
          "attacker" => "g1",
          "target" => "g2",
          "weapon" => "scimitar"
        })
      ]),
      text("g1 abate a g2."),
      tool_calls([
        call("make_attack", %{
          "attacker" => "g3",
          "target" => "Thane",
          "weapon" => "scimitar"
        })
      ]),
      text("g3 ataca."),
      text("El DM cierra."),
      text("ok")
    ]

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: dm_beats},
            turnmaster_model: %Test{label: "(no decision)"},
            roller: kill_roller()
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)

    snap = Game.snapshot(pid)
    assert snap.world.phase == :combat
    assert snap.world.characters["g2"].hp == 0
    cycle = World.combat_cycle(snap.world)
    refute "g2" in cycle
    assert "g1" in cycle
    assert "g3" in cycle
    assert "Thane" in cycle

    events = Games.list_events(game.id)
    dm_narr = Enum.filter(events, &(&1.actor == "dm" and &1.type == :narration))
    texts = Enum.map(dm_narr, &(&1.payload["text"] || ""))
    assert Enum.any?(texts, &(&1 =~ "g3 ataca"))
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

  defp two_humans_opts do
    [
      title: "tm intents",
      scene: "a torchlit ruin",
      roster: [
        {Archetypes.fighter(), :human},
        {Archetypes.wizard(), :human},
        {Monsters.goblin(), :ai}
      ],
      initiative: ["goblin", "Thane", "Lyra"]
    ]
  end

  test "queued human intent is visible to TurnMaster and can steal the floor" do
    {:ok, game} = Games.create_game(two_humans_opts())

    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("Lyra")
      }

    lyra_cast = [
      tool_calls([
        call("cast_spell", %{"caster" => "Lyra", "spell" => "firebolt", "target" => "goblin"})
      ]),
      text("Lyra lanza un rayo.")
    ]

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [
            model: %Test{script: dm_script() ++ lyra_cast},
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "me pongo delante del golpe")

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e -> e.type == :action and e.actor == "Lyra" end)
               end,
               10_000
             )

    refute Map.has_key?(Games.get_game(game.id).intents, "Lyra")
  end

  test "TurnMaster can keep the waiter; queued intent stays" do
    {:ok, game} = Games.create_game(two_humans_opts())

    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("Thane")
      }

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [model: %Test{script: dm_script()}, turnmaster_model: tm, roller: hit_roller()]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "abro la puerta")

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert Dragonex.Intents.text(Games.get_game(game.id).intents["Lyra"]) =~ "abro la puerta"
  end

  test "same queued text does not re-eval TurnMaster twice" do
    {:ok, game} = Games.create_game(two_humans_opts())

    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("Thane") ++
            tm_script_give("Thane")
      }

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [model: %Test{script: dm_script()}, turnmaster_model: tm, roller: hit_roller()]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)

    count = fn ->
      game.id
      |> Games.list_events()
      |> Enum.count(&(&1.actor == "turnmaster" and &1.type == :system))
    end

    before = count.()
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "salto")
    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    after_first = count.()
    assert after_first == before + 1

    assert {:ok, :queued} = Game.declare(pid, "Lyra", "salto")
    Process.sleep(80)
    assert count.() == after_first
    assert Game.status(pid) == :waiting
  end

  test "TurnMaster miss on re-eval keeps the waiter and the intent" do
    {:ok, game} = Games.create_game(two_humans_opts())

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

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "interrumpo")
    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert Dragonex.Intents.text(Games.get_game(game.id).intents["Lyra"]) =~ "interrumpo"
  end

  test "a combat reaction intent cuts in even if TurnMaster gave another actor" do
    {:ok, game} = Games.create_game(two_humans_opts())

    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("Thane")
      }

    pid =
      start_supervised!(
        {Dragonex.Game,
         {game.id,
          [model: %Test{script: dm_script()}, turnmaster_model: tm, roller: hit_roller()]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "interrumpo con Escudo")

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e ->
                   note = e.payload["note"] || ""
                   kind = e.payload["kind"]

                   e.actor == "turnmaster" and
                     (note =~ "interrumpe" or kind in ["cut_in", :cut_in])
                 end)
               end,
               10_000
             )
  end
end
