defmodule Dragonex.GameEngineRollCommitTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Game, Games, Monsters, Repo}
  alias Dragonex.Game.Combat
  alias ExAgent.{Session, Models.Test, Server}
  import Dragonex.Test.Harness

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "failed automatic initiative cannot publish a partial World or modal after SQL rollback" do
    {:ok, game} =
      Games.create_game(
        title: "La iniciativa se confirma entera",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(name: "g1"), :ai}]
      )

    before = Games.load_world(game)

    session =
      start_supervised!(
        {Session,
         shared_state: before, participants: [p("dm", :other), p("Thane", :human), p("g1", :ai)]}
      )

    assert {:ok, _} = Session.start(session)
    assert Session.current(session) == "dm"

    state = %Game{
      game_id: game.id,
      session: session,
      roller: fn _ -> 10 end,
      status: :paused,
      intents: %{}
    }

    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_engine_dice CHECK (game_id <> #{game.id} OR type <> 'dice' OR payload->>'who' <> 'g1')",
      []
    )

    # An outer transaction lets Sandbox inspect the failed transition too.
    # A DB rollback must never leave the live Session or a published modal ahead.
    try do
      Repo.transaction(fn -> Combat.maybe_force_combat(state, MapSet.new()) end)
    rescue
      Ecto.ConstraintError -> :ok
    catch
      :throw, {:engine_commit_failed, _} -> :ok
    end

    assert Session.read_state(session) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    refute_receive {:dice_group, _, _}, 20

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events DROP CONSTRAINT reject_test_engine_dice",
      []
    )

    assert %Game{} = Combat.maybe_force_combat(state, MapSet.new())
    committed = Session.read_state(session)
    assert committed.phase == :combat
    assert Games.load_world(Games.get_game(game.id)) == committed
    dice = Enum.filter(Games.list_events(game.id), &(&1.type == :dice))
    assert Enum.map(dice, & &1.payload["who"]) == ["Thane", "g1"]
    assert_receive {:dice_group, _, %{who: "Thane"}}, 500
    assert_receive {:dice_group, _, %{who: "g1"}}, 500
    refute_receive {:dice_group, _, _}, 20
  end

  for mode <- [:resume, :restart] do
    test "#{mode} retries rejected automatic initiative without another spawn or partial dice" do
      parent = self()
      spawn = tool_calls([call("spawn_monster", %{"kind" => "goblin", "name" => "g1"})])

      blocked = fn _, _ ->
        send(parent, {:spawn_ready, self()})
        receive do: (:finish -> narration("Thane, un goblin cierra el paso."))
      end

      {:ok, game} =
        Games.create_game(
          title: "Una iniciativa pendiente de guardar",
          roster: [{Archetypes.fighter(), :human}]
        )

      before = Games.load_world(game)
      {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)

      {:ok, pid} =
        Game.ensure_started(game.id,
          model: %Test{script: [spawn, blocked]},
          roller: fn _ -> 10 end
        )

      Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
      assert :ok == Game.resume(pid)
      assert_receive {:spawn_ready, request}, 2_000
      assert :ok == Game.pause(pid)
      spawned = Game.world(pid)
      assert Map.keys(spawned.characters) |> Enum.sort() == ["Thane", "g1"]
      assert spawned.actor_checkpoint != nil

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE game_events ADD CONSTRAINT reject_test_engine_dice CHECK (game_id <> #{game.id} OR type <> 'dice' OR payload->>'who' <> 'g1')",
        []
      )

      send(request, :finish)
      assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
      assert Game.status(pid) == :paused
      assert Dragonex.Game.Supervisor.whereis(game.id) == pid
      pending = Game.world(pid)
      assert pending.phase == :exploration
      assert pending.characters == spawned.characters

      assert pending.actor_checkpoint ==
               Map.put(spawned.actor_checkpoint, "pending_narration", true)

      assert Games.load_world(Games.get_game(game.id)) == pending
      saved_turn = pending.actor_checkpoint["turn_id"]
      saved_response = Games.completed_narration(game.id, "dm", saved_turn)
      assert saved_response == "Thane, un goblin cierra el paso."
      refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
      refute_receive {:dice_group, _, _}, 20

      assert Enum.any?(
               Games.list_events(game.id),
               &String.contains?(
                 &1.payload["note"] || "",
                 "No se pudo guardar la iniciativa automática"
               )
             )

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE game_events DROP CONSTRAINT reject_test_engine_dice",
        []
      )

      retry = %Test{
        script: [
          fn messages, _ ->
            world = Game.world(Dragonex.Game.Supervisor.whereis(game.id))

            send(
              parent,
              {:combat_actor_context, world.phase, inspect(messages, limit: :infinity)}
            )

            narration("El goblin vigila el paso.")
          end
        ]
      }

      recovered =
        if unquote(mode) == :restart do
          {:ok, recovered} = Game.restart(game.id, model: retry, roller: fn _ -> 10 end)
          recovered
        else
          assert :ok == Server.set_model(:sys.get_state(pid).dm, retry)
          pid
        end

      assert :ok == Game.resume(recovered)
      assert :ok == Game.await(recovered, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(recovered)
      world = Game.world(recovered)
      assert world.phase == :combat
      assert world.actor_checkpoint == nil
      assert world.characters == spawned.characters
      assert Games.load_world(Games.get_game(game.id)) == world
      dice = Enum.filter(Games.list_events(game.id), &(&1.type == :dice))
      assert length(dice) == 2
      assert Enum.map(dice, & &1.payload["who"]) == ["Thane", "g1"]
      assert_receive {:dice_group, _, %{who: "Thane"}}, 500
      assert_receive {:dice_group, _, %{who: "g1"}}, 500
      refute_receive {:dice_group, _, _}, 20
      # Recovery reuses the completed response; the next model request belongs
      # to the goblin's genuine combat turn, after initiative has committed.
      assert_receive {:combat_actor_context, :combat, context}, 1_000
      assert context =~ saved_response

      assert Enum.count(
               Games.list_events(game.id),
               &(&1.type == :narration and &1.payload["turn_id"] == saved_turn)
             ) == 1

      assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
