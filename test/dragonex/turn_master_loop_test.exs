defmodule Dragonex.TurnMasterLoopTest do
  @moduledoc """
  Fase B/C — TurnMaster integrated in the Game loop: handoff, WorldDriven
  fallback, mini-turns, acted_this_round.
  Uses :combat_handoffs => :turnmaster to exercise actual consultation after
  D113; the initiative floor still applies to every main decision.
  """

  use ExUnit.Case, async: false

  import Dragonex.Test.Harness
  import ExUnit.CaptureLog

  alias Dragonex.{Archetypes, Codec, Games, Game, Monsters, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
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
      narration("El DM sitúa la escena en la ruina."),
      tool_calls([
        call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})
      ]),
      narration("El goblin ataca."),
      narration("El DM cierra.")
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script()},
            combat_handoffs: :turnmaster,
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script()},
            combat_handoffs: :turnmaster,
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

  # Playtest 2026-09-16 (game 10790): a real LLM kept emitting valid tool calls
  # every step and never the final text — the TM beat spun to max_steps (3
  # calls, ~20-30s) before the WorldDriven fallback. Now the FIRST valid
  # decision is terminal (D79): the beat captures it via the run's PubSub
  # events, cancels the rest of the run and settles successfully — no warning,
  # no fallback.
  test "looping TM model settles on the first valid decision without warning or fallback" do
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
          Dragonex.Test.GameFixture.start!(
            {Game,
             {game.id,
              [
                model: %Test{script: dm_script() ++ [narration("ok")]},
                combat_handoffs: :turnmaster,
                turnmaster_model: looping_tm,
                roller: hit_roller()
              ]}}
          )

        # The captured decision is applied: the floor goes to the DM and the
        # partida keeps flowing instead of stalling on a failed beat.
        assert :ok ==
                 Game.await(
                   pid,
                   fn s ->
                     Enum.any?(s.events, fn e ->
                       e.actor == "turnmaster" and e.type == :system and
                         (e.payload["note"] || "") =~ "El turno pasa a goblin"
                     end)
                   end,
                   15_000
                 )

        assert Game.status(pid) in [:waiting, :running]
      end)

    # The beat settled via capture: no max_steps failure at all…
    refute log =~ "turnmaster beat failed"
    refute log =~ "max_steps_exceeded"

    events = Games.list_events(game.id)

    # …the decision was the TurnMaster's (system note), not WorldDriven's…
    assert Enum.any?(events, fn e ->
             e.actor == "turnmaster" and e.type == :system and
               (e.payload["note"] || "") =~ "El turno pasa a goblin"
           end)

    refute Enum.any?(events, fn e -> (e.payload["note"] || "") =~ "relevo" end)
    # …and the DM actually narrated after the handoff.
    assert Enum.any?(events, fn e -> e.actor == "dm" and e.type == :narration end)
  end

  # Companion of the capture test: a model whose calls NEVER record a decision
  # (bogus participant every step) gets no capture — the run burns its step
  # budget, the warning carries the tool-call evidence and WorldDriven keeps
  # the partida going (pre-capture behaviour, unchanged).
  test "TM model with only invalid targets still fails with evidence; WorldDriven keeps the partida going" do
    {:ok, game} =
      Games.create_game(
        title: "tm invalid loop",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    invalid_tm = %Test{
      script:
        List.duplicate(tool_calls([call("give_turn_to", %{"participant" => "merluzo"})]), 12)
    }

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game,
             {game.id,
              [
                model: %Test{script: dm_script() ++ [narration("ok")]},
                combat_handoffs: :turnmaster,
                turnmaster_model: invalid_tm,
                roller: hit_roller()
              ]}}
          )

        assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)
        # Soft fallback must not trip the pause circuit.
        assert Game.status(pid) in [:waiting, :running]
      end)

    assert log =~ "turnmaster beat failed"
    # …and the warning names what the model actually called (PubSub evidence).
    assert log =~ "give_turn_to"
    assert log =~ "merluzo"

    events = Games.list_events(game.id)
    assert Enum.any?(events, fn e -> e.type == :system end)
  end

  # The prompt contract (rule 1): after the decision tool-call the model
  # answers the exact text «listo», so well-behaved runs conclude on their own
  # — the classic short path, equivalent to a capture that arrived second.
  test "valid decision followed by the «listo» text settles the beat through the short path" do
    {:ok, game} =
      Games.create_game(
        title: "tm listo",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    tm =
      %Test{
        script:
          [
            tool_calls([call("give_turn_to", %{"participant" => "dm"})]),
            text("listo")
          ] ++ tm_script_give("Thane") ++ tm_script_give("dm")
      }

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game,
             {game.id,
              [
                model: %Test{script: dm_script()},
                combat_handoffs: :turnmaster,
                turnmaster_model: tm,
                roller: hit_roller()
              ]}}
          )

        assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)
      end)

    refute log =~ "turnmaster beat failed"

    events = Games.list_events(game.id)

    assert Enum.any?(events, fn e ->
             e.actor == "turnmaster" and e.type == :system and
               (e.payload["note"] || "") =~ "El turno pasa a goblin"
           end)

    refute Enum.any?(events, fn e -> (e.payload["note"] || "") =~ "relevo" end)
  end

  test "mute TM at exploration start passes to the DM without relevo" do
    {:ok, game} =
      Games.create_game(
        title: "opener",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}]
      )

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("El posadero limpia un vaso.")] ++ [narration("ok")]},
            combat_handoffs: :turnmaster,
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [
                narration("El caldero humea en la taberna."),
                narration("ok"),
                narration(
                  "El tabernero responde: —Hay guiso. Thane, ¿quieres preguntar algo más?"
                )
              ]
            },
            combat_handoffs: :turnmaster,
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
                 Enum.any?(s.events, fn e ->
                   e.type == :narration and e.actor == "dm" and
                     e.payload["complete"] == true and
                     e.payload["text"] ==
                       "El tabernero responde: —Hay guiso. Thane, ¿quieres preguntar algo más?"
                 end)
               end,
               10_000
             )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert :ok == Game.pause(pid)
    events = Games.list_events(game.id)
    refute Enum.any?(events, fn e -> (e.payload["note"] || "") =~ "relevo" end)
    refute Enum.any?(events, fn e -> (e.payload["note"] || "") =~ "el turno falló" end)

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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("Thane, el pergamino está cerrado. ¿Lo abres?")]},
            combat_handoffs: :turnmaster,
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script:
                [narration("El pergamino descansa en la mesa.")] ++
                  [narration("Thane se acerca.")] ++
                  [narration("Ábrelo tú, si quieres.")]
            },
            combat_handoffs: :turnmaster,
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
          narration("El DM sitúa la escena."),
          tool_calls([
            call("make_attack", %{
              "attacker" => name,
              "target" => "Thane",
              "weapon" => "scimitar"
            })
          ]),
          narration("#{name} ataca."),
          narration("El DM cierra.")
        ]
      end)

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_beats},
            combat_handoffs: :turnmaster,
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
          narration("El DM sitúa la escena."),
          tool_calls([
            call("make_attack", %{
              "attacker" => name,
              "target" => "Thane",
              "weapon" => "scimitar"
            })
          ]),
          narration("#{name} ataca."),
          narration("El DM cierra.")
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_beats},
            combat_handoffs: :turnmaster,
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
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
      narration("g1 abate a g2."),
      tool_calls([
        call("make_attack", %{
          "attacker" => "g3",
          "target" => "Thane",
          "weapon" => "scimitar"
        })
      ]),
      narration("g3 ataca."),
      narration("El DM cierra."),
      narration("ok")
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_beats},
            combat_handoffs: :turnmaster,
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
      narration("Thane intercepta.")
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script() ++ human_attack ++ dm_script()},
            combat_handoffs: :turnmaster,
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
    owner = self()

    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("Lyra")
      }

    lyra_action = [
      fn _, _ ->
        send(owner, {:queued_lyra_action_completed, self()})

        receive do
          :finish_queued_action -> narration("Me pongo delante del golpe.")
        after
          5_000 -> flunk("the queued action was not released")
        end
      end
    ]

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [narration("El goblin amaga un golpe desde la ruina.") | lyra_action]
            },
            combat_handoffs: :turnmaster,
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "me pongo delante del golpe")
    assert_receive {:queued_lyra_action_completed, request}, 2_000
    assert :ok == Game.pause(pid)
    send(request, :finish_queued_action)

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 s.status == :paused and :sys.get_state(pid).busy == nil and
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script()},
            combat_handoffs: :turnmaster,
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script()},
            combat_handoffs: :turnmaster,
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
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
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script()},
            combat_handoffs: :turnmaster,
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
    owner = self()

    tm =
      %Test{
        script:
          tm_script_give("dm") ++
            tm_script_give("Thane") ++
            tm_script_give("Thane")
      }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [
                narration("El goblin amaga un golpe desde la ruina."),
                tool_calls([
                  call("cast_spell", %{
                    "caster" => "Lyra",
                    "spell" => "shield",
                    "target" => "Lyra"
                  })
                ]),
                fn _, _ ->
                  send(owner, {:shield_reaction_completed, self()})

                  receive do
                    :finish_shield_reaction ->
                      narration("Alzo la mano y me cubro con mi escudo mágico.")
                  after
                    5_000 -> flunk("the shield reaction was not released")
                  end
                end
              ]
            },
            combat_handoffs: :turnmaster,
            turnmaster_model: tm,
            roller: hit_roller()
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    slots = Game.world(pid).spell_slots["Lyra"][1]
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "interrumpo con Escudo")
    assert_receive {:shield_reaction_completed, request}, 2_000
    assert :ok == Game.pause(pid)
    send(request, :finish_shield_reaction)

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 s.status == :paused and :sys.get_state(pid).busy == nil and
                   Enum.any?(s.events, fn e ->
                     note = e.payload["note"] || ""
                     kind = e.payload["kind"]

                     e.actor == "turnmaster" and
                       (note =~ "interrumpe" or kind in ["cut_in", :cut_in])
                   end)
               end,
               10_000
             )

    assert Game.world(pid).spell_slots["Lyra"][1] == slots - 1
    lyra = Game.world(pid).characters["Lyra"]
    assert lyra.ac == 12
    assert Dragonex.Rules.Effects.effective_ac(lyra) == 17
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end
end
