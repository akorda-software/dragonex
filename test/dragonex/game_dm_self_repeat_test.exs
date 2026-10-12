defmodule Dragonex.GameDMSelfRepeatTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for action <- [:pass_to_dm, :give_turn_to] do
    test "#{action} after an ordinary DM response cannot start a second DM beat and undeclared trip" do
      for count <- [0, 2] do
        companions = for n <- 1..count//1, do: {Archetypes.fighter(name: "Compañero #{n}"), :ai}
        roster = [{Archetypes.fighter(), :human} | companions]
        {:ok, game} = Games.create_game(title: "Recoger no es volver", roster: roster)
        world = Games.load_world(game)
        {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)

        {:ok, _} =
          Games.append_event(game.id, :turn, "Thane", "all", %{
            kind: "start",
            phase: "exploration",
            turn_kind: "main"
          })

        {:ok, _} =
          Games.append_event(game.id, :action, "Thane", "all", %{text: "Recojo el farol."})

        owner = self()

        model = %Test{
          script: [
            tool_calls([
              call("grant_item", %{
                "who" => "Thane",
                "item" => "farol de señales",
                "quantity" => 1
              })
            ]),
            narration("El farol queda registrado. La salida del cobertizo está despejada."),
            fn _, _ ->
              send(owner, :unexpected_second_dm)

              tool_calls([
                call("advance_time", %{"seconds" => 300}),
                call("remove_item", %{
                  "who" => "Thane",
                  "item" => "farol de señales",
                  "quantity" => 1
                })
              ])
            end,
            narration("La guardia recibe el farol."),
            narration("La guardia espera.")
          ]
        }

        args = if unquote(action) == :give_turn_to, do: %{"participant" => "dm"}, else: %{}

        tm = %Test{
          script: [tool_calls([call(Atom.to_string(unquote(action)), args)]), text("listo")]
        }

        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game.id, [model: model, turnmaster_model: tm]}}
          )

        assert :ok == Game.resume(pid)
        assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
        assert :ok == Game.pause(pid)
        refute_receive :unexpected_second_dm, 20
        after_world = Game.world(pid)
        assert after_world.elapsed_seconds == world.elapsed_seconds
        assert after_world.scene == world.scene

        assert Enum.find(
                 after_world.characters["Thane"].inventory,
                 &(&1.name == "farol de señales")
               ).qty == 1

        assert Games.load_world(Games.get_game(game.id)) == after_world

        turns =
          Games.list_events(game.id) |> Enum.filter(&(&1.type == :turn)) |> Enum.map(& &1.actor)

        assert turns == ["Thane", "dm"]
        assert :ok == stop_supervised({Game, game.id})
      end
    end
  end
end
