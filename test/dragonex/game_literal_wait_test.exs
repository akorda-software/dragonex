defmodule Dragonex.GameLiteralWaitTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, History}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  @wait "Espero cinco minutos junto a la barra."
  @answer "La taberna sigue tranquila. Thane, ¿qué deseas preguntar?"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(script) do
    hero = %{
      Archetypes.wizard(name: "Thane")
      | spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
    }

    {:ok, game} =
      Games.create_game(
        title: "Una espera literal",
        scene: "La barra de la taberna.",
        roster: [{hero, :human}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    scene = %Test{
      script: [
        tool_calls([
          call("final_result", %{"scene" => "La barra de la taberna continúa tranquila."})
        ])
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: script},
        scene_model: scene,
        roller: fn 4 -> 1 end
      )

    {game, pid, before}
  end

  defp start_turn(pid) do
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
  end

  test "only DM requests resolve a passive wait and read one exact human declaration" do
    parent = self()

    clock = fn messages, _ ->
      send(parent, {:literal_wait_request, inspect(messages, limit: :infinity)})
      tool_calls([call("advance_time", %{"seconds" => 300})])
    end

    final = fn messages, _ ->
      send(parent, {:literal_wait_request, inspect(messages, limit: :infinity)})
      narration(@answer)
    end

    {game, pid, before} = boot([clock, final])
    start_turn(pid)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    finish(pid)

    for _ <- 1..2 do
      assert_receive {:literal_wait_request, context}
      assert context =~ "ESPERA DECLARADA PENDIENTE"
      assert context =~ @wait
      refute context =~ "Estás resolviendo SOLO lo que Thane"
    end

    refute_received {:literal_wait_request, _}
    world = Game.world(pid)
    assert world.elapsed_seconds == 300
    assert world.characters == before.characters
    assert world.spell_slots == before.spell_slots
    assert world.rest_state == before.rest_state
    assert Games.load_world(Games.get_game(game.id)) == world
    events = Games.list_events(game.id)

    assert [%{payload: %{"text" => @wait, "complete" => true}}] =
             Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

    assert Enum.count(events, &(&1.type == :action and &1.actor == "Thane")) == 1

    assert [%{payload: %{"text" => @answer, "complete" => true}}] =
             Enum.filter(
               events,
               &(&1.type == :narration and &1.actor == "dm" and &1.payload["turn_id"] != nil)
             )

    assert inspect(History.from_events(events), limit: :infinity) =~ @wait
    refute Enum.any?(events, &(&1.type == :dice))
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "restart before the DM resolves keeps one literal speech and the unchanged clock" do
    parent = self()

    pending = fn messages, _ ->
      send(parent, {:literal_wait_pending, self(), inspect(messages, limit: :infinity)})
      receive do: (:finish -> narration(@answer))
    end

    {game, pid, before} = boot([pending])
    start_turn(pid)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", @wait)
    assert_receive {:literal_wait_pending, request, context}, 2_000
    assert context =~ "ESPERA DECLARADA PENDIENTE"
    assert Game.current(pid) == "dm"
    assert Game.world(pid) == before
    assert :ok == Game.pause(pid)
    monitor = Process.monitor(request)

    retry = %Test{
      script: [tool_calls([call("advance_time", %{"seconds" => 300})]), narration(@answer)]
    }

    assert {:ok, fresh} = Game.restart(game.id, model: retry)
    assert_receive {:DOWN, ^monitor, :process, ^request, _}, 1_000
    assert Game.world(fresh) == before
    assert :ok == Game.resume(fresh)
    finish(fresh)
    world = Game.world(fresh)
    assert world.elapsed_seconds == 300
    assert world.characters == before.characters
    assert Games.load_world(Games.get_game(game.id)) == world
    events = Games.list_events(game.id)

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "Thane" and &1.payload["text"] == @wait)
           ) == 1

    assert Enum.count(events, &(&1.type == :action)) == 1
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "a wait followed by a spell still uses the human beat and spends its slot and dice" do
    parent = self()

    human = fn messages, _ ->
      send(parent, {:mixed_wait_context, inspect(messages, limit: :infinity)})

      tool_calls([
        call("cast_spell", %{"caster" => "Thane", "target" => "Thane", "spell" => "false life"})
      ])
    end

    {game, pid, before} =
      boot([
        human,
        narration("La magia me protege."),
        tool_calls([call("advance_time", %{"seconds" => 300})]),
        narration(@answer)
      ])

    start_turn(pid)

    assert {:ok, :resolving} ==
             Game.declare(pid, "Thane", @wait <> " Luego lanzo False Life sobre mí.")

    finish(pid)
    assert_receive {:mixed_wait_context, context}
    assert context =~ "Estás resolviendo SOLO lo que Thane"
    world = Game.world(pid)
    assert world.characters["Thane"].temp_hp == 5
    assert world.spell_slots["Thane"][1] == before.spell_slots["Thane"][1] - 1
    assert world.elapsed_seconds == 300
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
    assert Games.load_world(Games.get_game(game.id)) == world
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "a paused queued wait neither publishes speech nor spends time until its turn is consumed" do
    parent = self()

    clock = fn messages, _ ->
      send(parent, {:queued_wait_request, inspect(messages, limit: :infinity)})
      tool_calls([call("advance_time", %{"seconds" => 300})])
    end

    {game, pid, before} = boot([clock, narration(@answer)])
    events_before = Games.list_events(game.id)
    assert {:ok, :queued} == Game.declare(pid, "Thane", @wait)
    assert Game.world(pid) == before
    assert Games.list_events(game.id) == events_before
    refute_received {:queued_wait_request, _}
    assert :ok == Game.resume(pid)
    finish(pid)
    assert_receive {:queued_wait_request, context}
    assert context =~ "ESPERA DECLARADA PENDIENTE"
    assert Game.world(pid).elapsed_seconds == 300
    action = Enum.find(Games.list_events(game.id), &(&1.type == :action))
    assert action.payload["clock_before"] == 0
    assert action.payload["wait_seconds"] == 300
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end
end
