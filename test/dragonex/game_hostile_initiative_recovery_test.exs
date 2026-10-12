defmodule Dragonex.GameHostileInitiativeRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Game, Games, Monsters, Repo, World}
  alias Dragonex.Game.Combat
  alias ExAgent.{Models.Test, Session}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(
        title: "Un hostil omitido",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.rogue(), :ai}]
      )

    {:ok, w} = World.add_character(Monsters.skeleton(name: "esqueleto")).(Games.load_world(game))
    {:ok, w} = World.begin_combat(["Vex", "Thane"]).(w)
    {:ok, w} = World.mark_acted("Vex").(w)
    {:ok, w} = World.set_current_combatant("Thane").(w)
    {:ok, w} = World.apply_damage("esqueleto", 9).(w)
    {:ok, _} = Games.save_state(game.id, w, "Thane", w.round, :paused)

    {:ok, _} =
      Games.append_event(game.id, :dice, "dm", "all", %{
        who: "Thane",
        kind: "initiative",
        dice: [[20, 13]],
        total: 14
      })

    before_events = Games.list_events(game.id)
    owner = self()

    model = %Test{
      script: [
        fn _, _ ->
          send(owner, :unexpected_recovery_model)
          "No debía pedirse una narración."
        end
      ]
    }

    roller = fn _ -> flunk("recovery must not invent an initial roll or repeat an effect") end

    {:ok, pid} =
      Game.ensure_started(game.id, model: model, turnmaster_model: model, roller: roller)

    %{
      game: game,
      pid: pid,
      opts: [model: model, turnmaster_model: model, roller: roller],
      before_events: before_events
    }
  end

  defp recovered(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
    Game.world(pid)
  end

  for mode <- [:resume, :restart] do
    test "#{mode} recovers once while preserving the human floor, spent turn and recorded dice",
         context do
      %{game: game, pid: initial, opts: opts, before_events: prefix} = context
      before = Game.world(initial)

      pid =
        if unquote(mode) == :restart do
          assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
          {:ok, _} = Games.set_status(game.id, :running)
          {:ok, reopened} = Game.ensure_started(game.id, opts)
          reopened
        else
          assert :ok == Game.resume(initial)
          initial
        end

      world = recovered(pid)
      assert world.initiative_order == ["Vex", "Thane", "esqueleto"]

      assert Map.drop(Map.from_struct(world), [:initiative_order, :log]) ==
               Map.drop(Map.from_struct(before), [:initiative_order, :log])

      assert Games.load_world(Games.get_game(game.id)) == world
      events = Games.list_events(game.id)
      assert Enum.take(events, length(prefix)) == prefix
      notes = Enum.filter(events, &(&1.payload["kind"] == "initiative_recovery"))
      assert [%{payload: %{"joined" => ["esqueleto"]}}] = notes
      assert :ok == Game.resume(pid)
      assert recovered(pid) == world

      assert Enum.count(
               Games.list_events(game.id),
               &(&1.payload["kind"] == "initiative_recovery")
             ) == 1

      refute_receive :unexpected_recovery_model, 20
    end
  end

  test "SQL rejects the entire recovery and resume retries without a partial Session or duplicate note",
       %{game: game, pid: pid, before_events: prefix} do
    before = Game.world(pid)
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_initiative_recovery CHECK (game_id <> #{game.id} OR payload->>'kind' IS DISTINCT FROM 'initiative_recovery')",
      []
    )

    assert {:error, :initiative_recovery_failed} = Game.resume(pid)
    assert Game.status(pid) == :paused and Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Enum.take(Games.list_events(game.id), length(prefix)) == prefix
    refute Enum.any?(Games.list_events(game.id), &(&1.payload["kind"] == "initiative_recovery"))
    refute_receive {:dice_group, _, _}, 20

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events DROP CONSTRAINT reject_test_initiative_recovery",
      []
    )

    assert :ok == Game.resume(pid)
    assert recovered(pid).initiative_order == ["Vex", "Thane", "esqueleto"]

    assert Enum.count(Games.list_events(game.id), &(&1.payload["kind"] == "initiative_recovery")) ==
             1

    refute_receive :unexpected_recovery_model, 20
  end

  test "in-flight and checkpointed beats keep their exact roster until their own settlement", %{
    pid: pid
  } do
    state = :sys.get_state(pid)
    busy = %{state | busy: :owned_attempt}
    assert {:ok, ^busy} = Combat.recover_hostile_initiative(busy)
    world = Session.read_state(state.session)

    for candidate <- [
          %{world | actor_checkpoint: %{"actor" => "dm", "turn_id" => "pending"}},
          %{world | pending_turn: %{"combatant" => "Thane", "kind" => "main"}}
        ] do
      assert {:ok, _} = Session.update_state(state.session, "Thane", fn _ -> {:ok, candidate} end)
      assert {:ok, ^state} = Combat.recover_hostile_initiative(state)
      assert Session.read_state(state.session) == candidate
    end
  end
end
