defmodule Dragonex.GameNarrationRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.Game.Supervisor, as: GameSupervisor
  alias ExAgent.{Models.Test, Server}

  @final "La mañana ilumina la posada. Thane, ¿qué quieres observar?"
  @scene "El cuarto de la posada por la mañana."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for mode <- [:restart, :kill] do
    test "#{mode} resumes a published DM response before settlement without requesting it again" do
      parent = self()

      {:ok, game} =
        Games.create_game(
          title: "La crónica conserva la mañana",
          scene: "La posada por la noche.",
          roster: [{Archetypes.fighter(), :human}]
        )

      world = Games.load_world(game)
      {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
      rest = call("rest_party", %{"targets" => ["Thane"], "kind" => "long"})

      model = %Test{
        script: [
          tool_calls([
            call("narrate", %{"text" => "La posada ofrece un lugar tranquilo para descansar."})
          ]),
          tool_calls([rest]),
          narration(@final)
        ]
      }

      recorder = %Test{
        script: [
          fn _, _ ->
            send(parent, {:after_published_response, self()})
            receive do: (:finish -> tool_calls([call("final_result", %{"scene" => @scene})]))
          end
        ]
      }

      {:ok, pid} = Game.ensure_started(game.id, model: model, scene_model: recorder)
      assert :ok == Game.resume(pid)
      assert_receive {:after_published_response, recording}, 2_000
      ref = Process.monitor(recording)

      try do
        assert :ok == Game.pause(pid)
        paid = Game.world(pid)
        turn_id = paid.actor_checkpoint["turn_id"]
        assert paid.elapsed_seconds == 28800
        assert Games.completed_narration(game.id, "dm", turn_id) == @final
        saved_speech = narration(game.id, turn_id)
        assert length(saved_speech) == 2
        assert Games.load_world(Games.get_game(game.id)) == paid

        unused = %Test{
          script: [
            fn ->
              send(parent, :unexpected_actor_request)
              "Una respuesta duplicada."
            end
          ]
        }

        scene = %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}

        reopened =
          if unquote(mode) == :restart do
            {:ok, fresh} = Game.restart(game.id, model: unused, scene_model: scene)
            fresh
          else
            Process.exit(pid, :kill)
            fresh = await_replacement(game.id, pid)
            assert :ok == Server.set_model(:sys.get_state(fresh).dm, unused)
            # Recovery needs only the independent scene recorder.
            :sys.replace_state(fresh, &%{&1 | scene_model: scene})
            fresh
          end

        assert Game.world(reopened) == paid
        assert_receive {:DOWN, ^ref, :process, ^recording, _}, 1_000
        assert :ok == Game.resume(reopened)
        assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
        assert :ok == Game.pause(reopened)
        final = Game.world(reopened)
        assert final.elapsed_seconds == 28800
        assert final.rest_state == paid.rest_state
        assert final.scene == @scene
        assert final.scene_refresh_pending == false
        assert final.actor_checkpoint == nil
        assert Games.load_world(Games.get_game(game.id)) == final
        assert narration(game.id, turn_id) == saved_speech

        assert Enum.count(Games.list_events(game.id), &(&1.type == :turn and &1.actor == "dm")) ==
                 1

        refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
        refute_received :unexpected_actor_request
      after
        GameSupervisor.stop_game(game.id)
        if Process.alive?(recording), do: Process.exit(recording, :kill)
      end
    end
  end

  defp narration(id, turn_id) do
    Games.list_events(id)
    |> Enum.filter(&(&1.type == :narration and &1.payload["turn_id"] == turn_id))
  end

  defp await_replacement(id, old, attempts \\ 200)
  defp await_replacement(_id, _old, 0), do: flunk("Game did not restart")

  defp await_replacement(id, old, attempts) do
    case GameSupervisor.whereis(id) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(5)
        await_replacement(id, old, attempts - 1)
    end
  end
end
