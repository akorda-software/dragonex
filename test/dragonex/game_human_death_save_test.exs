defmodule Dragonex.GameHumanDeathSaveTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Character, Codec, Game, Games, World}
  alias Dragonex.Game.{DeathSaveResolution, ToolReplay}
  alias ExAgent.Models.Test

  @declaration "Intento atacar al goblin con mi espada larga."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp death_save,
    do: tool_calls([call("make_death_save", %{"character" => "Thane"})])

  defp attack do
    tool_calls([
      call("make_attack", %{
        "attacker" => "Thane",
        "target" => "g1",
        "weapon" => "longsword",
        "mode" => "normal"
      })
    ])
  end

  defp closure, do: narration("La declaración queda registrada.")

  defp start_downed(script, rolls, opts \\ []) do
    thane = %{
      Archetypes.fighter()
      | hp: Keyword.get(opts, :hp, 0),
        death_saves: %{successes: 0, fails: 0}
    }

    companion = %{Archetypes.fighter() | name: "Mara"}
    enemy = Character.new(name: "g1", side: "enemy", hp: 30, max_hp: 30, ac: 12)

    {:ok, game} =
      Games.create_game(
        title: "Un humano caído conserva su salvación",
        locale: Keyword.get(opts, :locale, "es"),
        roster: [{thane, :human}, {companion, :human}, {enemy, :ai}],
        initiative: ["Thane", "Mara", "g1"]
      )

    world = Games.load_world(game)
    {:ok, world} = World.set_current_combatant("Thane").(world)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    remaining = start_supervised!({Agent, fn -> rolls end})
    owner = self()

    roller = fn sides ->
      Agent.get_and_update(remaining, fn
        [{^sides, value} | rest] -> {value, rest}
        other -> flunk("unexpected d#{sides}; remaining: #{inspect(other)}")
      end)
    end

    steps =
      for {item, index} <- Enum.with_index(script) do
        fn messages, params ->
          send(owner, {:resolver_request, index})
          if is_function(item, 2), do: item.(messages, params), else: item
        end
      end

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: steps}, roller: roller]}}
      )

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    declaration = Keyword.get(opts, :declaration, @declaration)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", declaration)

    %{
      game: game,
      pid: pid,
      before: world,
      remaining: remaining,
      roller: roller,
      declaration: declaration
    }
  end

  defp settled(context) do
    assert :ok ==
             Game.await(
               context.pid,
               &(&1.status == :paused or (&1.status == :waiting and &1.current == "Mara")),
               5_000
             )

    Game.world(context.pid)
  end

  defp assert_saved_once(context, world) do
    assert Game.status(context.pid) == :waiting
    assert Game.current(context.pid) == "Mara"
    assert world.turn_state["Thane"]["death_save"] == true
    assert world.acted_this_round == MapSet.new(["Thane"])
    assert world.characters["Mara"] == context.before.characters["Mara"]
    assert Agent.get(context.remaining, & &1) == []
    assert Games.load_world(Games.get_game(context.game.id)) == world
    events = Games.list_events(context.game.id)
    assert Enum.count(events, &(&1.type == :action and &1.actor == "Thane")) == 1

    assert [%{payload: %{"text" => declaration}}] =
             Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

    assert declaration == context.declaration

    assert Enum.count(events, &(&1.type == :dice and &1.payload["kind"] == "death_save")) == 1
    events
  end

  test "a human resolver cannot close a downed main turn before its death save" do
    context = start_downed([closure(), death_save(), closure()], [{20, 12}])
    world = settled(context)
    assert world.characters["Thane"].death_saves == %{successes: 1, fails: 0}
    assert world.characters["Thane"].hp == 0
    assert world.characters["g1"] == context.before.characters["g1"]
    refute world.turn_state["Thane"]["action"]
    events = assert_saved_once(context, world)
    assert Enum.count(events, &(&1.type == :dice)) == 1
    assert_receive {:resolver_request, 0}
    assert_receive {:resolver_request, 1}
    assert_receive {:resolver_request, 2}
    refute_receive {:resolver_request, 3}
  end

  test "a natural twenty after a rejected closure allows the declared attack in the same turn" do
    context =
      start_downed([closure(), death_save(), attack(), closure()], [{20, 20}, {20, 15}, {8, 4}])

    world = settled(context)
    assert world.characters["Thane"].hp == 1
    assert world.characters["Thane"].death_saves == %{successes: 0, fails: 0}
    assert world.characters["g1"].hp == 23
    assert world.turn_state["Thane"]["action"] == true
    events = assert_saved_once(context, world)

    assert ["death_save", "attack", "damage"] ==
             for(event <- events, event.type == :dice, do: event.payload["kind"])
  end

  test "an explicit death save already paid by the human resolver is not duplicated" do
    context = start_downed([death_save(), closure()], [{20, 12}])
    world = settled(context)
    assert world.characters["Thane"].death_saves == %{successes: 1, fails: 0}
    events = assert_saved_once(context, world)
    assert Enum.count(events, &(&1.type == :dice)) == 1
    assert_receive {:resolver_request, 0}
    assert_receive {:resolver_request, 1}
    refute_receive {:resolver_request, 2}
  end

  test "repeated omission pauses the same human turn without marking or publishing it" do
    context = start_downed([closure(), closure()], [])
    world = settled(context)
    assert Game.status(context.pid) == :paused
    assert Game.current(context.pid) == "Thane"
    assert world.acted_this_round == MapSet.new()
    assert world.characters == context.before.characters
    refute world.turn_state["Thane"]["death_save"]
    assert world.actor_checkpoint["actor"] == "Thane"
    assert world.actor_checkpoint["pending_narration"] == true
    assert Games.load_world(Games.get_game(context.game.id)) == world
    events = Games.list_events(context.game.id)
    assert Enum.count(events, &(&1.type == :action and &1.actor == "Thane")) == 1
    refute Enum.any?(events, &(&1.type == :narration and &1.actor == "Thane"))
    refute Enum.any?(events, &(&1.type == :dice))
  end

  test "an English table receives the pending save guide and corrective feedback in English" do
    corrected = fn messages, _params ->
      text = messages |> Dragonex.Test.ModelMessages.project() |> inspect(limit: :infinity)
      assert text =~ "PENDING DEATH SAVE"
      assert text =~ "Record the pending death save first"
      refute text =~ "SALVACIÓN DE MUERTE PENDIENTE"
      refute text =~ "Registra primero la salvación"
      death_save()
    end

    context = start_downed([closure(), corrected, closure()], [{20, 12}], locale: "en")
    world = settled(context)
    assert_saved_once(context, world)
  end

  test "a paid death save survives failure, JSON and restart without rolling again" do
    context = start_downed([death_save(), fn _, _ -> raise "after paid save" end], [{20, 12}])
    paused = settled(context)
    assert Game.status(context.pid) == :paused
    assert paused.characters["Thane"].death_saves == %{successes: 1, fails: 0}
    assert paused.actor_checkpoint["death_save_required"] == true
    restored = paused |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert ToolReplay.restore(restored, "Thane").death_save_required == true
    turn_id = paused.actor_checkpoint["turn_id"]

    stop_supervised!({Game, context.game.id})

    reopened =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {context.game.id,
          [model: %Test{script: [death_save(), closure()]}, roller: context.roller]}}
      )

    assert :ok == Game.resume(reopened)
    context = %{context | pid: reopened}
    world = settled(context)
    assert world.characters["Thane"].death_saves == %{successes: 1, fails: 0}
    events = assert_saved_once(context, world)
    assert Enum.count(events, &(&1.type == :turn and &1.payload["turn_id"] == turn_id)) == 1
  end

  test "starting conscious then falling during a paid action does not invent a save on retry" do
    cut =
      tool_calls([
        call("make_attack", %{
          "attacker" => "Thane",
          "target" => "Thane",
          "weapon" => "longsword",
          "mode" => "normal"
        })
      ])

    truncated = ExAgent.Message.new_response([], finish_reason: :length)
    context = start_downed([cut, truncated, closure()], [{20, 15}, {8, 4}], hp: 1)
    world = settled(context)
    assert Game.status(context.pid) == :waiting
    assert Game.current(context.pid) == "Mara"
    assert world.characters["Thane"].hp == 0
    assert world.characters["Thane"].death_saves == %{successes: 0, fails: 0}
    refute world.turn_state["Thane"]["death_save"]
    assert world.turn_state["Thane"]["action"] == true
    assert Agent.get(context.remaining, & &1) == []
    assert Games.load_world(Games.get_game(context.game.id)) == world
    events = Games.list_events(context.game.id)
    refute Enum.any?(events, &(&1.type == :dice and &1.payload["kind"] == "death_save"))
    assert Enum.count(events, &(&1.type == :dice)) == 2
  end

  describe "eligibility and receipts" do
    defp dying_world do
      %World{
        phase: :combat,
        turn_kind: "main",
        turn_owner: "Thane",
        current_combatant: "Thane",
        round: 2,
        characters: %{"Thane" => %{Archetypes.fighter() | hp: 0}},
        turn_state: %{"Thane" => %{"round" => 2}}
      }
    end

    test "stable, dead, healthy, AI, mini-turns, reactions and exploration do not qualify" do
      world = dying_world()
      assert DeathSaveResolution.required?(world, "Thane", true, false)
      refute DeathSaveResolution.required?(world, "Thane", false, false)
      refute DeathSaveResolution.required?(world, "Thane", true, true)
      refute DeathSaveResolution.required?(%{world | turn_kind: "reaction"}, "Thane", true, false)
      refute DeathSaveResolution.required?(%{world | phase: :exploration}, "Thane", true, false)
      refute DeathSaveResolution.required?(world, "Other", true, false)

      for sheet <- [
            %{world.characters["Thane"] | hp: 1},
            %{world.characters["Thane"] | death_saves: %{successes: 3, fails: 0}},
            %{world.characters["Thane"] | death_saves: %{successes: 0, fails: 3}}
          ] do
        excluded = put_in(world.characters["Thane"], sheet)
        refute DeathSaveResolution.required?(excluded, "Thane", true, false)
        assert DeathSaveResolution.resolved?(excluded, "Thane", 2)
      end
    end

    test "only this actor's paid save in the current round resolves an outstanding requirement" do
      world = dying_world()
      refute DeathSaveResolution.resolved?(world, "Thane", 2)
      previous = put_in(world.turn_state["Thane"], %{"round" => 1, "death_save" => true})
      refute DeathSaveResolution.resolved?(previous, "Thane", 2)
      other = put_in(world.turn_state["Mara"], %{"round" => 2, "death_save" => true})
      refute DeathSaveResolution.resolved?(other, "Thane", 2)
      paid = put_in(world.turn_state["Thane"]["death_save"], true)
      assert DeathSaveResolution.resolved?(paid, "Thane", 2)
    end

    test "JSON checkpoints retain explicit false and legacy checkpoints do not invent eligibility" do
      saved = %{
        "actor" => "Thane",
        "turn_id" => "downed-retry",
        "tools" => [],
        "pending_narration" => true,
        "phase" => "combat",
        "enemies_before" => [],
        "mini_turn" => false,
        "death_save_required" => false
      }

      for checkpoint <- [saved, Map.delete(saved, "death_save_required")] do
        world = %{dying_world() | actor_checkpoint: checkpoint}

        roundtrip =
          world |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()

        assert ToolReplay.restore(roundtrip, "Thane").death_save_required == false
      end
    end
  end
end
