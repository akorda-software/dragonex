defmodule Dragonex.GameWaitPacingTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games, World}
  alias Dragonex.Game.Instructions
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  @scene "La taberna del Ciervo tiene una barra de madera y un caldero humeante."
  @fact "Maribel dice que un forastero preguntaba por las semillas en el mercado."
  @wait "Espero treinta segundos junto a la barra."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game do
    {:ok, game} =
      Games.create_game(
        title: "Una espera deliberada no es un atasco",
        scene: @scene,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, before} = World.add_fact(@fact).(Games.load_world(game))
    {:ok, before} = World.advance_time(36_090).(before)
    before = %{before | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    {game, before}
  end

  defp observe(parent, stage, response) do
    fn messages, _params ->
      send(parent, {:wait_request, stage, ModelMessages.project(messages)})
      response
    end
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert :ok == Game.pause(pid)
  end

  defp assert_pacing(wire) do
    prompt = wire |> Enum.map_join("\n", &(&1["content"] || ""))
    assert prompt =~ "ESPERA DELIBERADA"
    assert prompt =~ "es una decisión, no un atasco"
    assert prompt =~ "No cierres investigaciones ni retires PNJs"
    assert prompt =~ "un suceso coherente con la campaña puede interrumpirla"
    assert prompt =~ "no determina la hora del día"
    refute prompt =~ "Si la escena lleva parada más de un turno, introduce algo NUEVO"
    refute prompt =~ "Actualiza el entorno o revela un detalle"
    refute prompt =~ "AVANCE OBLIGATORIO"
    assert prompt =~ @fact
    assert prompt =~ @wait
    assert prompt =~ "Respeta el estilo de partida"
  end

  test "a passive wait receives calm pacing before and after its clock tool, preserving the open lead" do
    {game, before} = game()
    parent = self()
    speech = "El caldero sigue humeando durante los treinta segundos."

    model = %Test{
      script: [
        observe(parent, :clock, tool_calls([call("advance_time", %{"seconds" => 30})])),
        observe(parent, :final, narration(speech))
      ]
    }

    recorder = %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, scene_model: recorder]}})

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    finish(pid)

    for stage <- [:clock, :final] do
      assert_receive {:wait_request, ^stage, wire}
      assert_pacing(wire)
      Jason.encode!(wire)
    end

    after_wait = Game.world(pid)
    assert after_wait.elapsed_seconds == 36_120
    assert after_wait.wait_resolution["elapsed_seconds"] == 30
    assert after_wait.scene == @scene
    refute after_wait.scene_refresh_pending
    assert after_wait.facts == before.facts

    assert Map.drop(after_wait, [:log, :elapsed_seconds, :wait_resolution]) ==
             Map.drop(before, [:log, :elapsed_seconds, :wait_resolution])

    assert Codec.decode(Codec.encode(after_wait)) == after_wait
    assert Games.load_world(Games.get_game(game.id)) == after_wait
    events = Games.list_events(game.id)
    refute Enum.any?(events, &(&1.type == :dice))

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == speech)
           ) == 1
  end

  test "calm pacing still allows a campaign event to interrupt a wait and survive a restart" do
    {game, before} = game()
    parent = self()
    speech = "Maribel llama desde la barra y corta la espera a los cinco segundos."

    model = %Test{
      script: [
        observe(parent, :clock, tool_calls([call("advance_time", %{"seconds" => 5})])),
        observe(parent, :final, narration(speech))
      ]
    }

    recorder = %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}
    {:ok, pid} = Game.ensure_started(game.id, model: model, scene_model: recorder)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    finish(pid)

    for stage <- [:clock, :final] do
      assert_receive {:wait_request, ^stage, wire}
      assert_pacing(wire)
    end

    after_wait = Game.world(pid)
    assert after_wait.elapsed_seconds == before.elapsed_seconds + 5
    assert after_wait.wait_resolution["declared_seconds"] == 30
    assert after_wait.wait_resolution["elapsed_seconds"] == 5
    assert after_wait.facts == before.facts
    assert after_wait.characters == before.characters
    events = Games.list_events(game.id)
    assert {:ok, fresh} = Game.restart(game.id, model: %Test{}, scene_model: %Test{})
    assert Game.world(fresh) == after_wait
    assert Games.load_world(Games.get_game(game.id)) == after_wait
    assert Games.list_events(game.id) == events
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "restart before clock resolution keeps deliberate pacing and charges the interval once" do
    {game, before} = game()
    parent = self()

    pending = fn messages, _ ->
      send(parent, {:wait_pending, self(), ModelMessages.project(messages)})
      receive do: (:finish -> narration("La espera todavía no se ha registrado."))
    end

    {:ok, pid} = Game.ensure_started(game.id, model: %Test{script: [pending]})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    assert_receive {:wait_pending, request, wire}, 2_000
    assert_pacing(wire)
    assert Game.world(pid) == before
    assert :ok == Game.pause(pid)
    ref = Process.monitor(request)
    speech = "Los treinta segundos pasan al calor del caldero."

    model = %Test{
      script: [
        observe(parent, :clock, tool_calls([call("advance_time", %{"seconds" => 30})])),
        observe(parent, :final, narration(speech))
      ]
    }

    recorder = %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}
    assert {:ok, fresh} = Game.restart(game.id, model: model, scene_model: recorder)
    assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
    assert Game.world(fresh) == before
    assert :ok == Game.resume(fresh)
    finish(fresh)

    for stage <- [:clock, :final] do
      assert_receive {:wait_request, ^stage, current_wire}
      assert_pacing(current_wire)
    end

    after_wait = Game.world(fresh)
    assert after_wait.elapsed_seconds == before.elapsed_seconds + 30
    assert after_wait.characters == before.characters
    assert after_wait.facts == before.facts
    assert Games.load_world(Games.get_game(game.id)) == after_wait
    events = Games.list_events(game.id)

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "Thane" and &1.payload["text"] == @wait)
           ) == 1

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == speech)
           ) == 1

    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "ordinary and real stall instructions retain their existing event guidance" do
    assert Instructions.dm_instruction() =~ "introduce algo NUEVO"
    assert Instructions.dm_advance_instruction() =~ "AVANCE OBLIGATORIO"
    assert Instructions.dm_post_combat_instruction() =~ "AVANCE OBLIGATORIO"
  end
end
