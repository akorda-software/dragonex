defmodule Dragonex.GameFactAuthorityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Brief, Codec, DM, Game, Games, PCAgent, Tools, World}
  alias ExAgent.{Message, Server, Session}
  alias ExAgent.Session.SharedState
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  @fact "Un hilo de lana oscura cuelga de una espina de retama junto al sendero."
  @scene "El sendero termina entre retamas. Un hilo de lana oscura cuelga de una espina."
  @human "Mara observa un hilo junto al sendero y espera la respuesta del mundo."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp record, do: tool_calls([call("establish_fact", %{"fact" => @fact})])

  defp scene_model do
    %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}
  end

  defp turnmaster do
    %Test{script: [tool_calls([call("give_turn_to", %{"participant" => "Mara"})]), "Listo."]}
  end

  defp begin do
    {:ok, game} =
      Games.create_game(
        title: "El DM confirma el descubrimiento",
        scene: "El sendero termina entre retamas.",
        roster: [{Archetypes.wizard(name: "Mara"), :human}]
      )

    before = %{Games.load_world(game) | scene_refresh_pending: false, elapsed_seconds: 40_635}
    {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
    # Ensure that role guidance is still delivered after the bounded roll archive.
    {:ok, _} =
      Games.append_event(game.id, :dice, "Mara", "all", %{
        who: "Mara",
        dice: [[20, 20]],
        total: 23,
        against: ["dc", 15],
        outcome: :success,
        reason: "chequeo antiguo",
        kind: :check
      })

    for n <- 1..401,
        do: Games.append_event(game.id, :system, "dm", "all", %{note: "Recuerdo #{n}."})

    parent = self()

    blocked = fn messages, _ ->
      send(parent, {:dm_confirmation_started, self(), ModelMessages.project(messages)})
      receive do: (:finish -> record())
    end

    model = %Test{
      script: [
        tool_calls([
          call("ability_check", %{
            "who" => "Mara",
            "ability" => "investigation",
            "dc" => 15,
            "mode" => "normal"
          })
        ]),
        tool_calls([
          call("establish_fact", %{
            "fact" => "Mara halló un hilo de lana oscura enganchado en una espina de retama."
          }),
          call("set_scene", %{"narration" => @scene})
        ]),
        fn messages, _ ->
          feedback =
            for %{parts: parts} <- messages,
                %{tool_name: name, content: content} <- parts,
                name in ["establish_fact", "set_scene"],
                do: {name, content}

          send(parent, {:human_world_feedback, feedback})
          narration(@human)
        end,
        blocked,
        narration(@fact)
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        scene_model: scene_model(),
        turnmaster_model: turnmaster(),
        roller: fn 20 -> 12 end
      )

    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(
               pid,
               "Mara",
               "Examino con Investigación las retamas sin avanzar ni recoger nada."
             )

    {game, pid, before}
  end

  defp before_confirmation(game, pid, before) do
    assert_receive {:human_world_feedback, feedback}, 2_000
    assert Enum.sort(Enum.map(feedback, &elem(&1, 0))) == ["establish_fact", "set_scene"]
    assert Enum.all?(feedback, &(inspect(elem(&1, 1)) =~ "RECHAZADO — solo el DM"))
    assert_receive {:dm_confirmation_started, request, wire}, 2_000
    assert Game.current(pid) == "dm"
    assert Game.world(pid).facts == before.facts
    assert Game.world(pid).scene == before.scene
    assert Games.load_world(Games.get_game(game.id)).facts == before.facts
    current = List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"]
    assert [_, after_archive] = String.split(current, "ARCHIVO DE TIRADAS", parts: 2)
    assert after_archive =~ "MEMORIA DE DESCUBRIMIENTOS"
    assert after_archive =~ "narrador humano"
    request
  end

  defp finish(game, pid, before) do
    assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    world = Game.world(pid)
    assert world.facts == [@fact]
    assert world.scene == @scene
    assert world.characters == before.characters
    assert world.elapsed_seconds == before.elapsed_seconds
    refute world.scene_refresh_pending
    assert world.actor_checkpoint == nil
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Codec.decode(Codec.encode(world)) == world

    assert [%{payload: %{"dice" => [[20, 12]], "total" => 15, "outcome" => "success"}}] =
             Games.list_events(game.id)
             |> Enum.filter(&(&1.type == :dice and &1.payload["reason"] != "chequeo antiguo"))

    assert Enum.count(Games.list_events(game.id), &(&1.type == :action)) == 1
  end

  test "human check and rejected world writes reach the DM; only its confirmation persists" do
    {game, pid, before} = begin()

    try do
      request = before_confirmation(game, pid, before)
      send(request, :finish)
      finish(game, pid, before)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart before DM confirmation preserves the check without replaying unauthorized world writes" do
    {game, pid, before} = begin()

    try do
      request = before_confirmation(game, pid, before)
      ref = Process.monitor(request)
      assert :ok = Game.pause(pid)
      paid = Game.world(pid)

      assert {:ok, fresh} =
               Game.restart(game.id,
                 model: %Test{script: [record(), narration(@fact)]},
                 scene_model: scene_model(),
                 turnmaster_model: turnmaster(),
                 roller: fn _ -> flunk("Check replayed") end
               )

      assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
      assert Game.world(fresh) == paid
      assert :ok = Game.resume(fresh)
      finish(game, fresh, before)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "DM-confirmed clues and legacy facts remain in both roles after prose is compacted" do
    legacy = "El zagal afirma: «No sé si el forastero sigue al norte»."

    world =
      World.new(
        characters: %{"Mara" => Archetypes.wizard(name: "Mara")},
        scene: "El sendero termina entre retamas.",
        facts: [legacy]
      )

    session =
      start_session(
        world: world,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Mara")]
      )

    assert {:ok, "dm"} = Session.start(session)
    ctx = %{deps: %{state: SharedState.new(session, "dm")}}
    assert {:ok, "hecho registrado"} = Tools.establish_fact(ctx, @fact)
    assert {:ok, "escena establecida"} = Tools.set_scene(ctx, @scene)
    confirmed = Session.read_state(session) |> Codec.encode() |> Codec.decode()
    assert confirmed.facts == [legacy, @fact]
    parent = self()

    for role <- [:dm, :pc] do
      summarizer = %Test{
        script: [
          fn _, _ ->
            send(parent, {:clue_summary_called, role})
            "Conversaron sobre el camino."
          end
        ]
      }

      model = %Test{
        script: [
          fn messages, _ ->
            send(parent, {:clue_after_compaction, role, ModelMessages.project(messages)})
            narration("El hilo sigue en la retama; el relato del zagal es una versión.")
          end
        ]
      }

      opts = [summarizer: summarizer, compaction_threshold: 1, compaction_keep_recent: 1]

      agent =
        if role == :dm,
          do: DM.new(model, opts),
          else: PCAgent.new(model, confirmed.characters["Mara"], opts)

      server =
        start_supervised!(
          {Server, agent: agent, agent_id: "clue-#{System.unique_integer([:positive])}-#{role}"}
        )

      history =
        for text <- [@human, "Hablaron del viento.", "La tarde sigue fresca."],
            do: Message.new_request([%Message.Part.User{content: text}])

      assert {:ok, _} =
               Dragonex.Agent.chat(
                 server,
                 Brief.turn_prompt(
                   confirmed,
                   if(role == :dm, do: "dm", else: "Mara"),
                   "Recuerda solo lo confirmado y conserva las dudas del relato."
                 ),
                 message_history: history
               )

      assert_receive {:clue_summary_called, ^role}
      assert_receive {:clue_after_compaction, ^role, wire}
      context = Enum.map_join(wire, "\n", &(&1["content"] || ""))
      assert context =~ @fact
      assert context =~ legacy
      refute context =~ @human
      assert Session.read_state(session) == confirmed
    end
  end
end
