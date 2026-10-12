defmodule Dragonex.GameCombatEndCommitTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Character, Game, Games, Intents, Repo, World}
  alias Dragonex.Game.Combat
  alias ExAgent.{Session, Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp fixture do
    hero = %{Archetypes.fighter() | raging: true, reckless: true}
    enemy = Character.new(name: "Goblin", side: "enemy", hp: 0, max_hp: 10)

    {:ok, game} =
      Games.create_game(
        title: "Un combate que se cierra entero",
        roster: [{hero, :human}, {Archetypes.wizard(), :human}, {enemy, :ai}]
      )

    world = Games.load_world(game)
    {:ok, world} = World.begin_combat(["Thane", "Lyra", "Goblin"]).(world)
    {:ok, world} = World.set_current_combatant("Thane").(world)

    intents = %{
      "Thane" => Intents.encode("Me interpongo ante el goblin", :combat),
      "Lyra" => Intents.encode("Observo el camino", :exploration)
    }

    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused, intents)
    {game, world, intents}
  end

  defp reject_note(game_id, note) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_combat_end CHECK (game_id <> #{game_id} OR type <> 'system' OR payload->>'note' IS DISTINCT FROM '#{note}')",
      []
    )
  end

  defp allow_note do
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events DROP CONSTRAINT reject_test_combat_end",
      []
    )
  end

  defp closing_notes(id) do
    Games.list_events(id)
    |> Enum.filter(
      &(&1.payload["note"] in [
          "⚔ El combate termina.",
          "La intención de Thane ya no aplica."
        ])
    )
  end

  for note <- ["⚔ El combate termina.", "La intención de Thane ya no aplica."] do
    test "rejecting #{note} rolls back phase, statuses, intents and all closure notes" do
      {game, before, intents} = fixture()

      session =
        start_supervised!(
          {Session,
           shared_state: before,
           participants: [p("dm", :other), p("Thane", :human), p("Lyra", :human)]}
        )

      assert {:ok, _} = Session.start(session)
      assert {:ok, _} = Session.handoff(session, "Thane")
      state = %Game{game_id: game.id, session: session, status: :running, intents: intents}
      reject_note(game.id, unquote(note))

      paused =
        try do
          Combat.maybe_end_combat(state)
        catch
          :throw, {:combat_end_commit_failed, paused} -> paused
        end

      assert Session.read_state(session) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert Games.get_game(game.id).intents == intents
      assert paused.intents == intents
      assert paused.status == :paused
      assert closing_notes(game.id) == []
      allow_note()
      committed = Combat.maybe_end_combat(%{paused | status: :running})
      world = Session.read_state(session)
      assert world.phase == :exploration
      assert world.current_combatant == nil
      refute world.characters["Thane"].raging
      refute world.characters["Thane"].reckless
      assert world.turn_state == %{}
      assert committed.intents == Map.take(intents, ["Lyra"])
      assert Games.load_world(Games.get_game(game.id)) == world
      assert Games.get_game(game.id).intents == committed.intents

      assert Enum.map(closing_notes(game.id), & &1.payload["note"]) == [
               "⚔ El combate termina.",
               "La intención de Thane ya no aplica."
             ]

      assert %Game{} = Combat.maybe_end_combat(committed)
      assert length(closing_notes(game.id)) == 2
    end
  end

  for mode <- [:resume, :restart] do
    test "#{mode} closes an already won fight before consuming its stale reaction" do
      {game, before, intents} = fixture()
      reject_note(game.id, "La intención de Thane ya no aplica.")
      model = %Test{script: [fn -> flunk("No actor may consume the stale combat intent") end]}

      {:ok, pid} =
        Game.ensure_started(game.id, model: model, roller: fn _ -> flunk("No new dice") end)

      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status in [:paused, :waiting]))
      assert Game.status(pid) == :paused
      assert Game.world(pid) == before
      assert Games.get_game(game.id).intents == intents
      assert closing_notes(game.id) == []
      allow_note()

      recovered =
        if unquote(mode) == :restart do
          {:ok, reopened} =
            Game.restart(game.id, model: model, roller: fn _ -> flunk("No new dice") end)

          reopened
        else
          pid
        end

      assert :ok == Game.resume(recovered)
      assert :ok == Game.await(recovered, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(recovered)
      assert Game.world(recovered).phase == :exploration
      assert Games.get_game(game.id).intents == Map.take(intents, ["Lyra"])
      assert length(closing_notes(game.id)) == 2
      assert Enum.all?(Games.list_events(game.id), &(&1.type != :dice))
      assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  for mode <- [:restart_before_feedback, :resume_after_failed_close, :restart_after_failed_close] do
    test "#{mode} preserves the winning attack's receipt until the fight closes" do
      parent = self()
      hero = %{Archetypes.fighter() | name: "Arden"}
      enemy = Character.new(name: "Goblin", side: "enemy", hp: 1, max_hp: 1, ac: 10)

      {:ok, game} =
        Games.create_game(
          title: "Un golpe ganador pendiente de narrar",
          roster: [{hero, :ai}, {Archetypes.fighter(), :human}, {enemy, :ai}],
          initiative: ["Arden", "Thane", "Goblin"]
        )

      before = Games.load_world(game)
      {:ok, before} = World.set_current_combatant("Arden").(before)
      {:ok, _} = Games.save_state(game.id, before, "Arden", before.round, :paused)
      values = start_supervised!({Agent, fn -> [10, 1] end})
      roller = fn _ -> Agent.get_and_update(values, fn [n | rest] -> {n, rest} end) end

      attack =
        tool_calls([
          call("make_attack", %{
            "attacker" => "Arden",
            "target" => "Goblin",
            "weapon" => "longsword",
            "mode" => "normal"
          })
        ])

      blocked = %Test{
        script: [
          if(unquote(mode) == :restart_before_feedback,
            do: attack,
            else:
              tool_calls([
                call("narrate", %{"text" => "Alzo la espada contra el goblin."})
                | elem(attack, 1)
              ])
          ),
          fn _, _ ->
            send(parent, {:winning_attack_applied, self()})
            receive do: (:finish -> narration("El goblin cae."))
          end
        ]
      }

      {:ok, pid} = Game.ensure_started(game.id, model: blocked, roller: roller)
      assert :ok == Game.resume(pid)
      assert_receive {:winning_attack_applied, request}, 2_000
      assert :ok == Game.pause(pid)
      paid = Game.world(pid)
      assert paid.characters["Goblin"].hp == 0
      assert paid.actor_checkpoint != nil

      if unquote(mode) != :restart_before_feedback do
        reject_note(game.id, "⚔ El combate termina.")
        send(request, :finish)
        assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
        assert Game.status(pid) == :paused
        assert Game.world(pid).phase == :combat
        expected = Map.put(paid.actor_checkpoint, "pending_narration", true)
        assert Game.world(pid).actor_checkpoint == expected
        assert Games.load_world(Games.get_game(game.id)).actor_checkpoint == expected
        assert closing_notes(game.id) == []
        allow_note()
      end

      retry = %Test{
        script: [
          attack,
          fn messages, _ ->
            send(parent, {:winning_receipt_recovered, messages})
            narration("Thane, el goblin ha caído.")
          end
        ]
      }

      reopened =
        if unquote(mode) == :resume_after_failed_close do
          assert :ok == Server.set_model(:sys.get_state(pid).pc_agents["Arden"], retry)
          pid
        else
          {:ok, fresh} = Game.restart(game.id, model: retry, roller: roller)
          fresh
        end

      expected =
        if unquote(mode) == :restart_before_feedback,
          do: paid.actor_checkpoint,
          else: Map.put(paid.actor_checkpoint, "pending_narration", true)

      assert Game.world(reopened).actor_checkpoint == expected

      assert :ok ==
               Server.set_model(:sys.get_state(reopened).dm, %Dragonex.Test.Narrator{
                 text: "Thane, ¿qué haces ahora?"
               })

      assert :ok == Game.resume(reopened)

      if unquote(mode) == :restart_before_feedback do
        assert_receive {:winning_receipt_recovered, messages}, 2_000
        assert inspect(messages, limit: :infinity) =~ "Resultado ya aplicado antes del fallo"
      end

      assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)

      if unquote(mode) != :restart_before_feedback do
        refute_receive {:winning_receipt_recovered, _}
      end

      final = Game.world(reopened)
      assert final.phase == :exploration
      assert final.actor_checkpoint == nil
      assert final.characters["Goblin"].hp == 0
      assert Agent.get(values, & &1) == []
      events = Games.list_events(game.id)
      assert Enum.count(events, &(&1.type == :dice)) == 2
      assert Enum.count(events, &(&1.payload["note"] == "⚔ El combate termina.")) == 1
      assert Enum.count(events, &(&1.type == :turn and &1.actor == "Arden")) == 1
      expected_speech = if unquote(mode) == :restart_before_feedback, do: 1, else: 2
      speech = Enum.filter(events, &(&1.type == :narration and &1.actor == "Arden"))
      assert length(speech) == expected_speech
      assert Enum.count(speech, &(&1.payload["complete"] == true)) == 1

      if unquote(mode) != :restart_before_feedback do
        assert Enum.map(speech, & &1.payload["text"]) == [
                 "Alzo la espada contra el goblin.",
                 "El goblin cae."
               ]
      end

      assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
