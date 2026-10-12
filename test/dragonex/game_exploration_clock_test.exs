defmodule Dragonex.GameExplorationClockTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, World}
  alias ExAgent.Models.Test
  alias ExAgent.Message.Part

  @walk "Camino durante quince minutos hasta el cruce del molino; allí me detengo sin tomar el desvío del bosque."
  @scene "El cruce del molino de piedra, con la noria junto a la acequia."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for mode <- [:complete, :restart] do
    test "#{mode}: a declared walk reaches the DM with the clock contract and expires effects once" do
      parent = self()

      {:ok, game} =
        Games.create_game(
          title: "El camino consume tiempo",
          scene: "La posada.",
          roster: [{Archetypes.fighter(), :human}]
        )

      before = Games.load_world(game)
      {:ok, before} = World.advance_time(32400).(before)
      {:ok, before} = World.set_inspired("Thane", true).(before)
      {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
      clock = tool_calls([call("advance_time", %{"seconds" => 900})])
      scene = tool_calls([call("set_scene", %{"narration" => @scene})])

      inspect_request = fn messages, _ ->
        text =
          messages
          |> Enum.flat_map(& &1.parts)
          |> Enum.map_join("\n", fn
            %Part.Text{content: t} -> t
            %Part.User{content: t} -> t
            %Part.System{content: t} -> t
            _ -> ""
          end)

        send(parent, {:dm_clock_request, text})
        clock
      end

      after_clock =
        if unquote(mode) == :restart do
          fn _, _ ->
            send(parent, {:clock_applied, self()})
            receive do: (:finish -> scene)
          end
        else
          scene
        end

      model = %Test{
        script: [
          narration("Me preparo para tomar el camino."),
          inspect_request,
          after_clock,
          narration("Thane, ¿qué quieres observar junto al molino?")
        ]
      }

      {:ok, pid} = Game.ensure_started(game.id, model: model)

      try do
        assert :ok == Game.resume(pid)
        assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
        assert {:ok, :resolving} == Game.declare(pid, "Thane", @walk)
        assert_receive {:dm_clock_request, context}, 2_000

        reopened =
          if unquote(mode) == :restart do
            assert_receive {:clock_applied, request}, 2_000
            ref = Process.monitor(request)
            assert :ok == Game.pause(pid)
            assert Game.world(pid).elapsed_seconds == 33300

            retry = %Test{
              script: [clock, scene, narration("Thane, ¿qué quieres observar junto al molino?")]
            }

            {:ok, fresh} = Game.restart(game.id, model: retry)
            assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
            assert :ok == Game.resume(fresh)
            fresh
          else
            pid
          end

        assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
        assert :ok == Game.pause(reopened)
        world = Game.world(reopened)
        assert world.elapsed_seconds == 33300
        assert world.characters["Thane"].inspired == false
        assert world.characters["Thane"].hp == before.characters["Thane"].hp
        assert world.rest_state == before.rest_state
        assert world.spell_slots == before.spell_slots
        assert world.scene == @scene
        assert Games.load_world(Games.get_game(game.id)) == world
        assert world.actor_checkpoint == nil
        refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
        assert context =~ @walk
        assert context =~ "Tiempo del mundo: 32400 s"
        assert context =~ "advance_time"
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end
end
