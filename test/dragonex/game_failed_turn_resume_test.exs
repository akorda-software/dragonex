defmodule Dragonex.GameFailedTurnResumeTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, Monsters}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  # D228: a monster's paid attack survives a failed DM beat. The table pauses
  # on that turn and resume finishes it, replaying the receipt instead of
  # rolling or damaging again.
  test "a failed monster turn pauses, and resume replays its paid attack once" do
    {:ok, game} =
      Games.create_game(
        title: "Ataque pagado",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(name: "g1"), :ai}]
      )

    # Initiative rolls in alphabetical order: Thane, g1; then attack and damage.
    dice = start_supervised!({Agent, fn -> [1, 20, 15, 1] end})

    roller = fn sides ->
      Agent.get_and_update(dice, fn
        [next | rest] -> {next, rest}
        [] -> {if(sides == 20, do: 15, else: 1), []}
      end)
    end

    attack =
      call("make_attack", %{
        "attacker" => "g1",
        "target" => "Thane",
        "weapon" => "scimitar",
        "mode" => "normal"
      })

    # A failed request does not advance the Test script, so the failing step
    # answers the rerun itself: first with the error, then with the repeat.
    failed = start_supervised!({Agent, fn -> false end}, id: :failed_once)

    model = %ExAgent.Models.Test{
      script: [
        tool_calls([call("roll_initiative", %{})]),
        tool_calls([attack]),
        fn _messages, _params ->
          if Agent.get_and_update(failed, &{&1, true}),
            do: tool_calls([attack]),
            else: raise("failure after committed attack")
        end,
        narration("El goblin retrocede con la cimitarra en alto.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: roller]}})
    assert :ok = Game.await(pid, &(&1.status == :paused), 5_000)

    paused = Game.world(pid)
    hp = paused.characters["Thane"].hp
    assert hp < paused.characters["Thane"].max_hp
    events = Games.list_events(game.id)
    dice_count = Enum.count(events, &(&1.type == :dice))

    assert [%{payload: %{"turn_id" => turn} = note, visible_to: "all"}] =
             Enum.filter(events, &(&1.payload["kind"] == "turn_retained"))

    assert note["note"] =~ "El turno del DM no pudo completarse"
    assert paused.actor_checkpoint["turn_id"] == turn
    refute Enum.any?(events, &(&1.type == :narration and &1.payload["turn_id"] == turn))
    assert Games.load_world(Games.get_game(game.id)) == paused

    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)

    world = Game.world(pid)
    events = Games.list_events(game.id)
    assert world.characters["Thane"].hp == hp
    assert Enum.count(events, &(&1.type == :dice)) == dice_count
    assert world.actor_checkpoint == nil
    assert MapSet.member?(world.acted_this_round, "g1")

    assert [%{payload: %{"complete" => true}}] =
             Enum.filter(events, &(&1.type == :narration and &1.payload["turn_id"] == turn))

    assert Enum.count(events, &(&1.type == :turn and &1.payload["turn_id"] == turn)) == 1
    refute Enum.any?(events, &(&1.payload["kind"] == "turn_skipped"))
    assert Games.load_world(Games.get_game(game.id)) == world
  end
end
