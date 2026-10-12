defmodule Dragonex.DMPuppetPCTest do
  @moduledoc """
  Bug #4 — the DM occasionally narrates a PC acting on its behalf ("*Lyra
  desenvaina y ataca*"), which rule 14 forbids. The prompt alone leaks through.

   Persist path (`Text.strip_puppet_clauses/2`, D29) drops subject-initial
   "<pc-name> <action-verb>" clauses. The detector/nudge still covers mid-clause
   leaks the strip leaves in place. Passive state ("Lyra cae herida") is kept.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Games, Game, World}
  alias Dragonex.Game.Guardrails
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  # Count :narration events produced by the DM, EXCLUDING the "La escena está
  # preparada" opening line (which isn't a model beat). The rule-14 nudge lands
  # on the DM beat AFTER a puppeteering narration, so we need at least two real
  # model narrations to observe it.
  defp dm_narration_count(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.count(fn e ->
      e.type == :narration and e.actor == "dm" and
        not String.starts_with?(e.payload["text"] || "", "La escena está preparada")
    end)
  end

  defp play_dm_script!(game, script) do
    owner = self()
    gate = make_ref()
    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, nil, before.round, :paused)

    finish = fn _, _ ->
      send(owner, {:dm_script_completed, gate, self()})

      receive do
        {:finish_dm_script, ^gate} -> List.last(script)
      after
        5_000 -> flunk("the completed DM script was not released")
      end
    end

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: Enum.drop(script, -1) ++ [finish]},
            roller: fn _ -> 10 end
          ]}}
      )

    state = :sys.get_state(pid)

    assert :ok ==
             Server.set_model(state.pc_agents["Lyra"], %Dragonex.Test.Narrator{
               text: "Me quedo en silencio."
             })

    assert :ok == Game.resume(pid)
    assert_receive {:dm_script_completed, ^gate, request}, 2_000
    assert :ok == Game.pause(pid)
    send(request, {:finish_dm_script, gate})

    assert :ok ==
             Game.await(
               pid,
               &(&1.status == :paused and :sys.get_state(pid).busy == nil),
               5_000
             )

    refute Enum.any?(
             Games.list_events(game.id),
             &String.contains?(&1.payload["note"] || "", "el turno falló")
           )

    pid
  end

  test "subject-initial puppet clauses are stripped before persist" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    script = [
      "Lyra ataca el aire con su daga, probando el peso del arma. La cripta espera.",
      "Un viento frío recorre la cripta."
    ]

    play_dm_script!(game, Enum.map(Enum.take(script, 1), &narration/1))
    assert dm_narration_count(game.id) == 1

    texts =
      game.id
      |> Games.list_events()
      |> Enum.filter(&(&1.type == :narration and &1.actor == "dm"))
      |> Enum.map(&(&1.payload["text"] || ""))
      |> Enum.reject(&String.starts_with?(&1, "La escena está preparada"))

    joined = Enum.join(texts, " ")
    refute joined =~ ~r/Lyra ataca/i
    assert joined =~ "La cripta espera"
  end

  test "the live tavern regression is sanitized before entering the shared agent history" do
    raw = File.read!(Path.expand("../fixtures/narration/dm_tavern_puppet.txt", __DIR__))

    {:ok, game} =
      Games.create_game(
        title: "Taberna",
        scene: "una taberna",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: [narration(raw)]}, roller: fn _ -> 10 end]}}
      )

    assert :ok = Game.await_turn(pid, "Thane")
    assert :ok = Game.pause(pid)

    texts = Dragonex.History.from_events(Games.list_events(game.id)) |> inspect()
    assert texts =~ "Borin os mira"
    refute texts =~ "Lyra deja"
    refute texts =~ "¿Alguien más ha notado"
    refute texts =~ "Vex asiente"
  end

  test "the six-PC live dialogue is removed before persistence and shared history" do
    raw = File.read!(Path.expand("../fixtures/narration/dm_six_party_puppet.txt", __DIR__))

    {:ok, game} =
      Games.create_game(
        title: "El grupo completo",
        scene: "una posada",
        roster: [
          {%{Archetypes.fighter() | name: "Iria del Alba"}, :human},
          {Archetypes.wizard(), :ai},
          {%{Archetypes.wizard() | name: "Mara de la Bruma"}, :ai},
          {%{Archetypes.rogue() | name: "Nera del Camino"}, :ai},
          {Archetypes.fighter(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: [narration(raw)]}]}}
      )

    assert :ok = Game.await_turn(pid, "Iria del Alba")
    assert :ok = Game.pause(pid)
    history = Dragonex.History.from_events(Games.list_events(game.id)) |> inspect()
    refute history =~ "estrenar estos pergaminos"
    refute history =~ "Lyra, la elfa maga, alza"
    refute history =~ "Nera del Camino afina"
    assert history =~ "Mara de la Bruma guarda silencio"
    assert history =~ "¿Qué hace el grupo?"
  end

  test "the real short-name opening is clean in persistence and shared history without resource changes" do
    raw = File.read!(Path.expand("../fixtures/narration/dm_sira_short_name.txt", __DIR__))
    name = "Sira de la Chispa"

    {:ok, game} =
      Games.create_game(
        title: "La chispa",
        scene: "un cuarto junto al río",
        roster: [{Archetypes.wizard(name: name), :human}]
      )

    before = Games.load_world(game)

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: [narration(raw)]}]}}
      )

    assert :ok = Game.await(pid, &(&1.current == name and &1.status == :waiting))
    assert :ok = Game.pause(pid)

    world = Game.world(pid)
    assert world.characters == before.characters
    assert world.elapsed_seconds == before.elapsed_seconds
    assert world.rest_state == before.rest_state
    assert world.scene == before.scene
    assert Games.load_world(Games.get_game(game.id)) == world

    events = Games.list_events(game.id)

    persisted =
      Enum.find(
        events,
        &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] =~ "ozono")
      )

    assert persisted.payload["text"] =~ "El cuarto se llena de un leve olor a ozono."
    assert persisted.payload["text"] =~ "muchacho pálido del gremio de barqueros"
    refute persisted.payload["text"] =~ "deja caer"
    history = Dragonex.History.from_events(events) |> inspect()
    assert history =~ "La señora del muelle lo pidió"
    refute history =~ "deja caer"
  end

  test "registered NPC full-name speech survives a PC-name prefix in the real Game event path" do
    {:ok, game} =
      Games.create_game(
        title: "Dos voces",
        scene: "el muelle",
        roster: [{Archetypes.wizard(), :human}]
      )

    npc = %{Archetypes.fighter(name: "Lyra del Muelle") | side: "npc"}
    {:ok, before} = World.add_character(npc).(Games.load_world(game))
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    raw = "«Volved al amanecer», dice Lyra del Muelle. «Aceptamos», dice Lyra."

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: [narration(raw)]}]}}
      )

    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == "Lyra" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    assert Game.world(pid).characters == before.characters

    history = Dragonex.History.from_events(Games.list_events(game.id)) |> inspect()
    assert history =~ "Volved al amanecer"
    assert history =~ "dice Lyra del Muelle"
    refute history =~ "Aceptamos"
  end

  test "mid-clause puppet leak still triggers a rule-14 reminder" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    # Does not start with the PC name, so the structural strip keeps it;
    # the looser detector still nudges the next beat.
    script = [
      "Entre las sombras, junto a un pilar, Lyra ataca el aire.",
      "La cripta guarda silencio."
    ]

    log =
      capture_log(fn ->
        play_dm_script!(game, Enum.map(script, &narration/1))
        assert dm_narration_count(game.id) == 2
      end)

    assert log =~ "reinforcing rule 14"
  end

  test "detector catches playtest-style puppet leaks (pure)" do
    pcs = ["Lyra", "Vex", "Rhogar"]

    assert Guardrails.dm_narration_puppets_pc?(
             "Lyra, sonriendo, conjura firebolt contra el maniquí.",
             pcs
           )

    assert Guardrails.dm_narration_puppets_pc?(
             "Vex ya tensa su arco corto, mirando de reojo.",
             pcs
           )

    assert Guardrails.dm_narration_puppets_pc?(
             "Vex aprovecha el descuido del sabueso y dispara desde el flanco.",
             pcs
           )

    refute Guardrails.dm_narration_puppets_pc?(
             "Lyra está herida junto a la valla.",
             pcs
           )

    refute Guardrails.dm_narration_puppets_pc?(
             "El sabueso se abalanza contra Rhogar.",
             pcs
           )
  end

  test "narration that only describes the world does NOT trip the detector" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    # Legitimate world narration mentioning a PC by name (no action verb) — the
    # detector must not fire and slander the DM.
    script = [
      "La luz temblorosa revela glifos junto a donde está Lyra.",
      "Un viento frío recorre la cripta."
    ]

    log =
      capture_log(fn ->
        play_dm_script!(game, Enum.map(script, &narration/1))
        assert dm_narration_count(game.id) == 2
      end)

    refute log =~ "reinforcing rule 14",
           "world narration that merely mentions a PC must not trip the puppet detector"
  end
end
