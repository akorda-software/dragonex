defmodule Dragonex.GameBusyStageTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Item}
  alias ExAgent.Models.Test

  @scene "El patio sigue vacío."
  @final "El botón está en la bolsa. Thane, ¿qué haces?"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp new_game do
    {:ok, game} =
      Games.create_game(
        title: "Etapas de espera",
        scene: @scene,
        roster: [{%{Archetypes.fighter() | inventory: []}, :human}]
      )

    world = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    {game, world}
  end

  defp block(parent, tag, response) do
    fn _, _ ->
      send(parent, {tag, self()})
      receive do: (:finish -> response)
    end
  end

  defp give do
    tool_calls([call("grant_item", %{"who" => "Thane", "item" => "botón", "quantity" => 1})])
  end

  defp scene_result, do: tool_calls([call("final_result", %{"scene" => @scene})])

  defp wait(pid) do
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert :ok = Game.pause(pid)
    assert Game.snapshot(pid).busy_stage == nil
  end

  test "published narration yields to scene review; stale signals and pause do not change the world" do
    {game, before} = new_game()
    owner = self()

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [block(owner, :actor_started, give()), narration(@final)]},
            scene_model: %Test{script: [block(owner, :review_started, scene_result())]}
          ]}}
      )

    assert Game.snapshot(pid).busy_stage == nil
    assert :ok = Game.resume(pid)
    assert_receive {:actor_started, actor_run}, 2_000
    assert %{status: :running, current: "dm", busy_stage: :acting} = Game.snapshot(pid)

    beat = :sys.get_state(pid).busy
    send(pid, {:scene_review_started, self(), beat.turn_id})
    send(pid, {:scene_review_started, beat.pid, "otro-turno"})
    assert Game.snapshot(pid).busy_stage == :acting
    assert Game.world(pid) == before

    send(actor_run, :finish)
    assert_receive {:review_started, recorder}, 2_000
    assert :ok = Game.await(pid, &(&1.busy_stage == :scene_review))
    snap = Game.snapshot(pid)
    assert snap.status == :running
    assert snap.current == "dm"
    assert Enum.count(snap.events, &(&1.type == :narration and &1.payload["text"] == @final)) == 1
    assert [%Item{qty: 1}] = snap.world.characters["Thane"].inventory
    assert snap.world.scene_refresh_pending
    assert Games.load_world(Games.get_game(game.id)) == snap.world

    send(pid, {:scene_review_started, actor_run, beat.turn_id})
    assert Game.snapshot(pid).busy_stage == :scene_review
    assert Game.world(pid) == snap.world
    assert Games.list_events(game.id) == snap.events

    assert :ok = Game.pause(pid)
    assert Game.snapshot(pid).busy_stage == nil
    assert :ok = Game.resume(pid)
    assert Game.snapshot(pid).busy_stage == :scene_review
    assert Game.world(pid) == snap.world
    assert Games.list_events(game.id) == snap.events

    send(recorder, :finish)
    wait(pid)
    settled = Game.world(pid)
    refute settled.scene_refresh_pending
    assert %{before | characters: settled.characters} == settled
    events = Games.list_events(game.id)
    send(pid, {:scene_review_started, beat.pid, beat.turn_id})
    assert Game.snapshot(pid).busy_stage == nil
    assert Game.world(pid) == settled
    assert Games.list_events(game.id) == events
  end

  test "TurnMaster reports its own stage even while the session cursor still points at the DM" do
    {game, before} = new_game()
    decision = tool_calls([call("give_turn_to", %{"participant" => "Thane"})])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("El patio está tranquilo.")]},
            turnmaster_model: %Test{script: [block(self(), :handoff_started, decision), "Listo."]},
            scene_model: %Test{}
          ]}}
      )

    assert :ok = Game.resume(pid)
    assert_receive {:handoff_started, run}, 2_000
    snap = Game.snapshot(pid)
    assert snap.current == "dm"
    assert snap.busy_stage == :turnmaster
    assert snap.world == before

    assert Enum.count(
             snap.events,
             &(&1.type == :narration and &1.payload["text"] == "El patio está tranquilo.")
           ) == 1

    beat = :sys.get_state(pid).busy
    send(pid, {:scene_review_started, beat.pid, beat.turn_id})
    assert Game.snapshot(pid).busy_stage == :turnmaster
    send(run, :finish)
    wait(pid)
    assert Game.world(pid) == before
  end

  test "restart rebuilds pending review without repeating the final narration or the confirmed inventory" do
    {game, _before} = new_game()

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: [give(), narration(@final)]},
        scene_model: %Test{script: [block(self(), :review_started, scene_result())]}
      )

    try do
      assert :ok = Game.resume(pid)
      assert_receive {:review_started, old_recorder}, 2_000
      assert :ok = Game.await(pid, &(&1.busy_stage == :scene_review))
      assert :ok = Game.pause(pid)
      saved = Game.world(pid)
      events = Games.list_events(game.id)
      old_beat = :sys.get_state(pid).busy
      monitor = Process.monitor(old_recorder)

      {:ok, fresh} =
        Game.restart(game.id,
          model: %Test{label: "No debe volver a narrar."},
          scene_model: %Test{script: [block(self(), :review_restarted, scene_result())]}
        )

      assert fresh != pid
      assert_receive {:DOWN, ^monitor, :process, ^old_recorder, _}, 1_000
      assert %{status: :paused, busy_stage: nil} = Game.snapshot(fresh)
      assert Game.world(fresh) == saved
      assert Games.list_events(game.id) == events
      send(fresh, {:scene_review_started, old_beat.pid, old_beat.turn_id})
      assert Game.snapshot(fresh).busy_stage == nil

      assert :ok = Game.resume(fresh)
      assert_receive {:review_restarted, new_recorder}, 2_000
      assert :ok = Game.await(fresh, &(&1.busy_stage == :scene_review))
      send(fresh, {:scene_review_started, old_beat.pid, old_beat.turn_id})
      assert Game.snapshot(fresh).busy_stage == :scene_review
      assert Game.world(fresh) == saved
      send(new_recorder, :finish)
      wait(fresh)
      assert [%Item{qty: 1}] = Game.world(fresh).characters["Thane"].inventory
      refute Game.world(fresh).scene_refresh_pending

      assert Games.list_events(game.id)
             |> Enum.count(&(&1.type == :narration and &1.payload["text"] == @final)) == 1

      refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
