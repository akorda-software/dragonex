defmodule Dragonex.GameNPCStatementTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Brief, Codec, DM, Game, Games, History, PCAgent}
  alias ExAgent.{Message, Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @question "Le pregunto a la posadera: «¿Viste tú misma marcharse al forastero o te lo contó alguien?» Espero aquí su respuesta."
  @claim "No vi marcharse al forastero; ayer el herrero me dijo que tomó el camino del norte, pero no sé si sigue por allí."
  @fact "Maribel afirma: «#{@claim}» [Registrado a los 37935 s del reloj del mundo.]"
  @human "—¿Viste tú misma marcharse al forastero o te lo contó alguien?"
  @speech "Maribel deja el trapo. —No lo vi marcharse. El herrero me dijo que tomó el camino del norte, pero no sé si sigue por allí."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game do
    {:ok, game} =
      Games.create_game(
        title: "El rumor conserva su fuente",
        scene: "La barra de madera y el caldero de la taberna.",
        story_bible: %{"pnj" => "Maribel es la posadera; el herrero conoce los caminos."},
        roster: [{Archetypes.fighter(), :human}]
      )

    before = %{Games.load_world(game) | elapsed_seconds: 37_935}
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    {game, before}
  end

  defp record,
    do:
      tool_calls([call("record_npc_statement", %{"speaker" => "Maribel", "statement" => @claim})])

  defp begin_question(pid) do
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
  end

  defp assert_memory(before, after_world) do
    assert after_world.facts == [@fact]
    assert Map.drop(after_world, [:facts]) == Map.drop(before, [:facts])
    assert Codec.decode(Codec.encode(after_world)) == after_world
  end

  test "a real NPC response carries the tool, saves attributed testimony and returns without scene or TurnMaster requests" do
    {game, before} = game()
    parent = self()

    model = %Test{
      script: [
        fn messages, params ->
          send(parent, {:npc_statement_request, ModelMessages.project(messages), params})
          record()
        end,
        narration(@speech)
      ]
    }

    unexpected = fn _, _ ->
      send(parent, :unexpected_statement_auxiliary)
      "No debe haber una petición adicional."
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        turnmaster_model: %Test{script: [unexpected]},
        scene_model: %Test{script: [unexpected]}
      )

    begin_question(pid)
    finish(pid)
    assert_receive {:npc_statement_request, wire, params}
    prompt = Enum.map_join(wire, "\n", &(&1["content"] || ""))
    assert prompt =~ "record_npc_statement"
    assert prompt =~ "conserva quién lo afirma, sus dudas y de quién lo supo"
    assert prompt =~ "No conviertas una versión o rumor en hecho confirmado"
    assert Enum.any?(params.function_tools, &(&1.name == "record_npc_statement"))
    refute_received :unexpected_statement_auxiliary
    after_world = Game.world(pid)
    assert_memory(before, after_world)
    assert Games.load_world(Games.get_game(game.id)) == after_world
    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :narration and &1.payload["text"] == @speech)) == 1
    assert Enum.count(events, &(&1.type == :action)) == 1

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "Thane" and &1.payload["text"] == @human)
           ) == 1

    refute Enum.any?(events, &(&1.type == :dice))
    assert inspect(History.from_events(events), limit: :infinity) =~ @speech
    assert {:ok, fresh} = Game.restart(game.id, model: %Test{})
    assert Game.world(fresh) == after_world
    assert Games.list_events(game.id) == events
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "restart after saving the testimony replays its result without a duplicate fact or physical change" do
    {game, before} = game()
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:testimony_saved, self()})
      receive do: (:finish -> narration(@speech))
    end

    {:ok, pid} = Game.ensure_started(game.id, model: %Test{script: [record(), blocked]})
    begin_question(pid)
    assert_receive {:testimony_saved, request}, 2_000
    paid = Game.world(pid)
    assert paid.facts == [@fact]
    assert paid.actor_checkpoint != nil
    assert Games.load_world(Games.get_game(game.id)) == paid
    assert :ok == Game.pause(pid)
    ref = Process.monitor(request)

    final = fn messages, _ ->
      send(parent, {:replayed_testimony, ModelMessages.project(messages)})
      narration(@speech)
    end

    assert {:ok, fresh} = Game.restart(game.id, model: %Test{script: [record(), final]})
    assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
    assert Game.world(fresh) == paid
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert_receive {:replayed_testimony, wire}
    content = inspect(wire, limit: :infinity)
    assert content =~ "Resultado ya aplicado antes del fallo"
    assert content =~ "el contenido no se considera confirmado"
    after_world = Game.world(fresh)
    assert after_world.actor_checkpoint == nil
    assert_memory(before, after_world)
    assert Games.load_world(Games.get_game(game.id)) == after_world

    assert Enum.count(
             Games.list_events(game.id),
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == @speech)
           ) == 1

    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "DM and PC requests retain the attributed fact even when a summary omits the old NPC dialogue" do
    {game, before} = game()
    assert {:ok, world} = Dragonex.World.record_npc_statement("Maribel", @claim).(before)
    assert {:ok, world} = Dragonex.World.advance_time(86_400).(world)
    parent = self()

    for role <- [:dm, :pc] do
      summarizer = %Test{
        script: [
          fn messages, _ ->
            send(parent, {:statement_summary, role, ModelMessages.project(messages)})
            "Han conversado en la taberna."
          end
        ]
      }

      model = %Test{
        script: [
          fn messages, _ ->
            send(
              parent,
              {:statement_after_compaction, role, ModelMessages.project(messages)}
            )

            narration("Aún queda por comprobar esa versión.")
          end
        ]
      }

      opts = [summarizer: summarizer, compaction_threshold: 1, compaction_keep_recent: 1]

      agent =
        case role do
          :dm -> DM.new(model, opts)
          :pc -> PCAgent.new(model, Archetypes.fighter(), opts)
        end

      server = start_supervised!({Server, agent: agent, agent_id: "testimony-#{game.id}-#{role}"})

      history =
        Enum.map(
          [@speech, "Después hablaron del caldero.", "El caldero sigue humeando."],
          fn text ->
            Message.new_request([%Message.Part.User{content: text}])
          end
        )

      assert {:ok, _} =
               Dragonex.Agent.chat(
                 server,
                 Brief.turn_prompt(
                   world,
                   if(role == :dm, do: "dm", else: "Thane"),
                   "Recuerda lo que sabemos."
                 ),
                 message_history: history
               )

      assert_receive {:statement_summary, ^role, summary_wire}
      assert inspect(summary_wire, limit: :infinity) =~ "Conserva la fuente y las dudas"
      assert_receive {:statement_after_compaction, ^role, wire}
      prompt = Enum.map_join(wire, "\n", &(&1["content"] || ""))
      assert prompt =~ @fact
      assert prompt =~ "Tiempo del mundo: 124335 s"
      assert prompt =~ "no al reloj actual"
      assert prompt =~ "no confirman por sí solos su contenido"
      assert prompt =~ "Han conversado en la taberna."
      refute prompt =~ @speech
      Jason.encode!(wire)
    end
  end
end
