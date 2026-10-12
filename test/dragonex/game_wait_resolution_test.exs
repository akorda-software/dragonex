defmodule Dragonex.GameWaitResolutionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, World}
  alias ExAgent.Models.Test

  @wait "Espero veinte minutos junto a la barra mientras termino mi guiso. Luego le cuento a Maribel cómo recuperamos el saquito del goblin en el granero y espero aquí su reacción."
  @human "Me dispongo a terminar el guiso junto a la barra."
  @scene "La barra de la taberna está despejada, con un cuenco vacío."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game do
    {:ok, game} =
      Games.create_game(
        title: "Una espera se resuelve en el motor",
        scene: "La barra de la taberna.",
        roster: [{Archetypes.fighter(), :human}]
      )

    before = Games.load_world(game)
    {:ok, before} = World.advance_time(32400).(before)
    {:ok, before} = World.set_inspired("Thane", true).(before)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    {game, before}
  end

  defp scene_model do
    %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}
  end

  defp start(game, script) do
    Dragonex.Test.GameFixture.start!(
      {Game, {game.id, [model: %Test{script: script}, scene_model: scene_model()]}}
    )
  end

  defp declare(pid) do
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
  end

  defp resources_preserved(before, world) do
    assert world.characters["Thane"].hp == before.characters["Thane"].hp
    assert world.rest_state == before.rest_state
    assert world.spell_slots == before.spell_slots
  end

  test "an omitted clock call cannot publish a completed wait; the next request must resolve time" do
    {game, before} = game()
    owner = self()

    required = fn _messages, params ->
      send(owner, {:clock_required, params.output_mode, params.allow_text_output})
      tool_calls([call("advance_time", %{"seconds" => 1200})])
    end

    final = fn _messages, _params ->
      send(
        owner,
        {:clock_settled, Game.world(Dragonex.Game.Supervisor.whereis(game.id)).elapsed_seconds}
      )

      narration("Maribel recoge el cuenco vacío. Thane, ¿qué quieres preguntarle?")
    end

    pid =
      start(game, [
        narration(@human),
        narration("Han pasado veinte minutos, pero no llamo ninguna herramienta."),
        required,
        final
      ])

    declare(pid)
    finish(pid)

    assert_receive {:clock_required, :tool, false}
    assert_receive {:clock_settled, 33600}
    world = Game.world(pid)
    assert world.elapsed_seconds == 33600
    refute world.characters["Thane"].inspired
    resources_preserved(before, world)
    assert Games.load_world(Games.get_game(game.id)) == world

    events = Games.list_events(game.id)
    action = Enum.find(events, &(&1.type == :action))
    assert action.payload["wait_seconds"] == 1200
    assert action.payload["clock_before"] == 32400
    refute Enum.any?(events, &((&1.payload["text"] || "") =~ "no llamo ninguna herramienta"))
    refute Enum.any?(events, &(&1.type == :dice))

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["complete"] == true)
           ) == 1
  end

  test "repeated clock calls for one declared interval do not charge it again" do
    {game, before} = game()
    clock = tool_calls([call("advance_time", %{"seconds" => 1200})])
    duplicate = tool_calls([call("advance_time", %{"seconds" => 600})])

    pid =
      start(game, [
        narration(@human),
        clock,
        clock,
        duplicate,
        narration("El cuenco está vacío. Thane, ¿qué deseas observar?")
      ])

    declare(pid)
    finish(pid)

    assert Game.world(pid).elapsed_seconds == 33600
    resources_preserved(before, Game.world(pid))
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end

  test "parallel clock calls commit the interval only once" do
    {game, before} = game()
    clocks = tool_calls(for _ <- 1..2, do: call("advance_time", %{"seconds" => 1200}))

    pid =
      start(game, [
        narration(@human),
        clocks,
        narration("Maribel retira el cuenco. Thane, ¿qué deseas observar?")
      ])

    declare(pid)
    finish(pid)
    assert Game.world(pid).elapsed_seconds == 33600
    assert Game.world(pid).wait_resolution["elapsed_seconds"] == 1200
    resources_preserved(before, Game.world(pid))
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end

  test "a duration above the declaration is rejected before the corrected call" do
    {game, before} = game()
    too_long = tool_calls([call("advance_time", %{"seconds" => 1800})])
    correct = tool_calls([call("advance_time", %{"seconds" => 1200})])

    pid =
      start(game, [
        narration(@human),
        too_long,
        correct,
        narration("El cuenco está vacío. Thane, ¿qué deseas observar?")
      ])

    declare(pid)
    finish(pid)
    assert Game.world(pid).elapsed_seconds == 33600
    resources_preserved(before, Game.world(pid))
  end

  test "a supervised restart after a partial commit cannot charge the full wait" do
    {game, before} = game()
    owner = self()
    partial = tool_calls([call("advance_time", %{"seconds" => 60})])

    stop_after_clock = fn _, _ ->
      send(owner, {:partial_wait_committed, self()})
      receive do: (:finish -> narration("La llamada de Maribel interrumpe la espera."))
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: [narration(@human), partial, stop_after_clock]},
        scene_model: scene_model()
      )

    try do
      declare(pid)
      assert_receive {:partial_wait_committed, request}, 2_000
      monitor = Process.monitor(request)
      assert Game.world(pid).elapsed_seconds == 32460
      assert Game.world(pid).wait_resolution["elapsed_seconds"] == 60
      assert :ok == Game.pause(pid)

      retry = %Test{
        script: [
          tool_calls([call("advance_time", %{"seconds" => 1200})]),
          narration("La espera ya fue interrumpida. Thane, ¿qué respondes a Maribel?")
        ]
      }

      assert {:ok, fresh} = Game.restart(game.id, model: retry, scene_model: scene_model())
      assert fresh != pid
      assert_receive {:DOWN, ^monitor, :process, ^request, _}, 1_000
      assert :ok == Game.resume(fresh)
      finish(fresh)
      assert Game.world(fresh).elapsed_seconds == 32460
      assert Game.world(fresh).actor_checkpoint == nil
      assert Game.world(fresh).wait_resolution["elapsed_seconds"] == 60
      resources_preserved(before, Game.world(fresh))
      assert Games.load_world(Games.get_game(game.id)) == Game.world(fresh)
      assert Enum.count(Games.list_events(game.id), &(&1.type == :action)) == 1
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  for seconds <- [0, 60] do
    test "an interruption can resolve only #{seconds} seconds without completing the planned twenty minutes" do
      {game, before} = game()
      clock = tool_calls([call("advance_time", %{"seconds" => unquote(seconds)})])

      pid =
        start(game, [
          narration(@human),
          clock,
          narration("La llamada de Maribel interrumpe la espera. Thane, ¿qué le respondes?")
        ])

      declare(pid)
      finish(pid)

      assert Game.world(pid).elapsed_seconds == before.elapsed_seconds + unquote(seconds)
      assert Game.world(pid).characters["Thane"].inspired
      resources_preserved(before, Game.world(pid))
      assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    end
  end

  test "failure before recording the wait pauses with its declaration intact and a restart can resolve it once" do
    {game, before} = game()

    pid =
      start(game, [
        narration(@human),
        narration("Omito el reloj."),
        narration("Sigo omitiendo el reloj.")
      ])

    declare(pid)
    assert :ok == Game.await(pid, &(&1.status == :paused and &1.current == "dm"))
    assert Map.drop(Game.world(pid), [:actor_checkpoint]) == Map.drop(before, [:actor_checkpoint])
    assert Game.world(pid).actor_checkpoint["pending_narration"] == true

    assert Enum.any?(
             Games.list_events(game.id),
             &((&1.payload["note"] || "") =~ "No se pudo completar la narración")
           )

    refute Enum.any?(Games.list_events(game.id), &((&1.payload["text"] || "") =~ "omitiendo"))
    assert :ok == stop_supervised({Game, game.id})

    fresh =
      start(game, [
        tool_calls([call("advance_time", %{"seconds" => 1200})]),
        narration("El guiso se enfría. Thane, ¿qué deseas observar?")
      ])

    assert fresh != pid
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert Game.world(fresh).elapsed_seconds == 33600
    resources_preserved(before, Game.world(fresh))
    assert Enum.count(Games.list_events(game.id), &(&1.type == :action)) == 1
    assert Games.load_world(Games.get_game(game.id)) == Game.world(fresh)
  end
end
