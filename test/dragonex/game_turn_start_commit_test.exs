defmodule Dragonex.GameTurnStartCommitTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Actions, Character, Codec, Game, Games, Repo, World}
  alias Dragonex.Game.Combat
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Session, Models.Test}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp fixture do
    cleric =
      Character.new(
        name: "Cora",
        class: "cleric",
        level: 5,
        hp: 30,
        max_hp: 30,
        wis: 16,
        spells: [Spells.to_character_spell(Spells.get("spirit guardians"), :wis)]
      )

    enemy =
      Character.new(
        name: "Goblin",
        side: "enemy",
        hp: 100,
        max_hp: 100,
        wis: 8,
        concentrating: "bless"
      )

    {:ok, game} =
      Games.create_game(
        title: "Un aura confirmada entera",
        roster: [{cleric, :human}, {enemy, :ai}]
      )

    world = Games.load_world(game)

    {:ok, _, cast} =
      Actions.spell(world, "Cora", "spirit guardians", "Goblin", fn _ ->
        flunk("casting must not roll")
      end)

    {:ok, world} = cast.(world)
    {:ok, world} = World.begin_combat(["Cora", "Goblin"]).(world)
    {:ok, _} = Games.save_state(game.id, world, nil, world.round, :paused)
    {game, world}
  end

  defp reject_damage(game_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_turn_start CHECK (game_id <> #{game_id} OR type <> 'dice' OR payload->>'kind' <> 'damage')",
      []
    )
  end

  defp allow_damage do
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events DROP CONSTRAINT reject_test_turn_start",
      []
    )
  end

  defp dice(id), do: Enum.filter(Games.list_events(id), &(&1.type == :dice))

  test "rejecting the second start-turn group leaves effects and all dice private" do
    {game, before} = fixture()

    session =
      start_supervised!(
        {Session, shared_state: before, participants: [p("dm", :other), p("Cora", :human)]}
      )

    assert {:ok, _} = Session.start(session)
    assert {:ok, _} = Session.handoff(session, "Cora")

    state = %Game{
      game_id: game.id,
      session: session,
      roller: fn _ -> 1 end,
      status: :running,
      intents: %{}
    }

    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    reject_damage(game.id)

    paused = Combat.start_turn(state, "Cora")

    pending = Session.read_state(session)
    assert pending.characters == before.characters
    assert pending.turn_state == before.turn_state
    assert pending.current_combatant == before.current_combatant
    assert Map.get(pending, :pending_turn) == %{"combatant" => "Cora", "kind" => "main"}
    assert Games.load_world(Games.get_game(game.id)) == pending
    assert paused.status == :paused
    assert dice(game.id) == []
    refute_receive {:dice_group, _, _}, 20
    allow_damage()
    assert %Game{} = Combat.start_turn(%{paused | status: :running}, "Cora")
    committed = Session.read_state(session)
    assert committed.characters["Goblin"].hp == 97
    assert committed.characters["Goblin"].concentrating == nil
    assert Map.get(committed, :pending_turn) == nil
    assert Games.load_world(Games.get_game(game.id)) == committed
    assert Enum.map(dice(game.id), & &1.payload["kind"]) == ["save", "damage", "save"]
    for kind <- [:save, :damage, :save], do: assert_receive({:dice_group, _, %{kind: ^kind}})
    refute_receive {:dice_group, _, _}, 20
  end

  for mode <- [:resume, :restart] do
    test "#{mode} retries the saved turn start before an actor can act" do
      {game, before} = fixture()
      counter = start_supervised!({Agent, fn -> 0 end})

      roller = fn _ ->
        Agent.update(counter, &(&1 + 1))
        1
      end

      reject_damage(game.id)

      {:ok, pid} =
        Game.ensure_started(game.id,
          model: %Dragonex.Test.Narrator{text: "Cora, espera."},
          roller: roller
        )

      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status == :paused))
      assert Dragonex.Game.Supervisor.whereis(game.id) == pid
      pending = Game.world(pid)
      assert pending.characters == before.characters
      assert Map.get(pending, :pending_turn) == %{"combatant" => "Cora", "kind" => "main"}
      assert Games.load_world(Games.get_game(game.id)) == pending
      assert dice(game.id) == []
      assert Agent.get(counter, & &1) == 5
      allow_damage()

      recovered =
        if unquote(mode) == :restart do
          {:ok, reopened} =
            Game.restart(game.id,
              model: %Dragonex.Test.Narrator{text: "Cora, espera."},
              roller: roller
            )

          reopened
        else
          pid
        end

      assert :ok == Game.resume(recovered)
      assert :ok == Game.await(recovered, &(&1.current == "Cora" and &1.status == :waiting))
      assert :ok == Game.pause(recovered)
      final = Game.world(recovered)
      assert final.characters["Goblin"].hp == 97
      assert final.characters["Goblin"].concentrating == nil
      assert Map.get(final, :pending_turn) == nil
      assert Games.load_world(Games.get_game(game.id)) == final
      assert length(dice(game.id)) == 3
      assert Agent.get(counter, & &1) == 10
      {:ok, reopened} = Game.restart(game.id, model: %Test{}, roller: roller)
      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Cora" and &1.status == :waiting))
      assert Agent.get(counter, & &1) == 10
      assert length(dice(game.id)) == 3
      assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a saved named DM slot is prepared before the model, without choosing another enemy" do
    {game, world} = fixture()
    parent = self()

    {:ok, world} =
      World.add_character(Character.new(name: "Goblin2", side: "enemy", hp: 20)).(world)

    {:ok, world} = World.end_combat().(world)
    {:ok, world} = World.begin_combat(["Cora", "Goblin", "Goblin2"]).(world)
    pending = %{world | pending_turn: %{"combatant" => "Goblin2", "kind" => "main"}}
    {:ok, _} = Games.save_state(game.id, pending, "dm", pending.round, :paused)

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, :named_slot_prepared)
          receive do: (:finish -> narration("Espera."))
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        roller: fn _ -> flunk("this slot must not roll") end
      )

    assert :ok == Game.resume(pid)
    assert_receive :named_slot_prepared, 2_000
    assert :ok == Game.pause(pid)
    final = Game.world(pid)
    assert final.current_combatant == "Goblin2"
    assert final.turn_owner == "Goblin2"
    assert final.turn_state["Goblin2"]["round"] == final.round
    refute Map.has_key?(final.turn_state, "Goblin")
    assert final.pending_turn == nil
    assert Games.load_world(Games.get_game(game.id)) == final
    assert dice(game.id) == []
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "a saved reaction preserves its main owner and does not run start-turn effects" do
    {game, world} = fixture()
    parent = self()
    {:ok, world} = World.set_current_combatant("Cora", "main", fn _ -> 1 end).(world)
    pending = %{world | pending_turn: %{"combatant" => "Goblin", "kind" => "reaction"}}
    {:ok, _} = Games.save_state(game.id, pending, "dm", pending.round, :paused)

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, :reaction_prepared)
          receive do: (:finish -> narration("Reacciono."))
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        roller: fn _ -> flunk("a reaction must not roll turn effects") end
      )

    assert :sys.get_state(pid).pending_mini
    assert :ok == Game.resume(pid)
    assert_receive :reaction_prepared, 2_000
    assert :ok == Game.pause(pid)
    final = Game.world(pid)
    assert final.turn_kind == "reaction"
    assert final.turn_owner == "Cora"
    assert final.current_combatant == "Goblin"
    assert final.characters == world.characters
    assert final.turn_state == world.turn_state
    assert final.pending_turn == nil
    assert :sys.get_state(pid).busy.mini_turn
    assert Games.load_world(Games.get_game(game.id)) == final
    assert dice(game.id) == []
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "the pending named slot survives JSON; legacy and invalid markers do not become turns" do
    {_, world} = fixture()
    marker = %{"combatant" => "Goblin", "kind" => "reaction"}
    pending = Map.put(world, :pending_turn, marker)
    encoded = pending |> Codec.encode() |> Jason.encode!() |> Jason.decode!()
    assert Map.get(Codec.decode(encoded), :pending_turn) == marker
    assert Map.get(Codec.decode(Map.delete(encoded, "pending_turn")), :pending_turn) == nil

    for invalid <- [
          nil,
          [],
          %{},
          %{"combatant" => "missing", "kind" => "main"},
          %{"combatant" => "Goblin", "kind" => "invented"}
        ] do
      assert Map.get(Codec.decode(Map.put(encoded, "pending_turn", invalid)), :pending_turn) ==
               nil
    end
  end
end
