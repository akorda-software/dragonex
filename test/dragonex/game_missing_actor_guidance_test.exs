defmodule Dragonex.GameMissingActorGuidanceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.Test.ModelMessages
  alias ExAgent.Models.Test

  test "DM registers the missing monster after rejection before initiative, preserving the PCs and dice" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(title: "El actor aún no existe", roster: [{Archetypes.fighter(), :human}])

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    owner = self()

    script = [
      tool_calls([
        call("make_attack", %{
          "attacker" => "esqueleto",
          "target" => "Thane",
          "weapon" => "shortsword"
        })
      ]),
      fn messages, _ ->
        feedback =
          ModelMessages.project(messages)
          |> Enum.filter(&(&1["role"] == "tool"))
          |> Enum.map_join("\n", & &1["content"])

        send(owner, {:missing_actor_feedback, feedback})
        tool_calls([call("spawn_monster", %{"kind" => "skeleton", "name" => "esqueleto"})])
      end,
      tool_calls([call("roll_initiative", %{})]),
      narration("El esqueleto sale del cobertizo y comienza el combate.")
    ]

    rolls = start_supervised!({Agent, fn -> [20, 1] end})
    roller = fn 20 -> Agent.get_and_update(rolls, fn [value | rest] -> {value, rest} end) end

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: script}, roller: roller]}}
      )

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
    assert_receive {:missing_actor_feedback, error}
    assert error =~ "no existe" and error =~ "spawn_monster"
    refute error =~ "DEBE ser \"dm\""
    world = Game.world(pid)
    assert world.phase == :combat and Enum.sort(world.initiative_order) == ["Thane", "esqueleto"]
    assert world.characters["Thane"] == before.characters["Thane"]
    assert world.characters["esqueleto"].hp == 13
    dice = Games.list_events(game.id) |> Enum.filter(&(&1.type == :dice))

    assert Enum.map(dice, &{&1.payload["who"], &1.payload["kind"], &1.payload["dice"]}) == [
             {"Thane", "initiative", [[20, 20]]},
             {"esqueleto", "initiative", [[20, 1]]}
           ]

    assert Games.load_world(Games.get_game(game.id)) == world
    assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
  end
end
