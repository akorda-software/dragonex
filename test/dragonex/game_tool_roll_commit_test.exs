defmodule Dragonex.GameToolRollCommitTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Actions, Character, Game, Games, Repo, Tools}
  alias Dragonex.Game.ToolReplay
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server}
  alias ExAgent.Session.SharedState
  import Dragonex.Test.Harness

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "a prepared spell cannot publish dice before its World effect is committed" do
    {game, pid, before} = prepared_spell()
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert :ok == Game.resume(pid)
    assert_receive {:spell_prepared, tool}, 2_000

    try do
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 0
      refute_receive {:dice_group, _, _}, 20

      assert :ok == Game.pause(pid)
      send(tool, :commit)
      assert_receive {:spell_outcome, {:ok, _}, _ctx}, 2_000
      paid = Game.world(pid)
      assert paid.spell_slots["Mara"][1] == 1
      assert paid.characters["Goblin"].hp == 14
      assert Games.load_world(Games.get_game(game.id)) == paid
      assert [%{"values" => [receipt]}] = paid.actor_checkpoint["tools"]
      assert receipt =~ "ya aplicó su cambio"
      assert [event] = dice_events(game.id)
      assert event.payload["turn_id"] == paid.actor_checkpoint["turn_id"]
      assert event.payload["dice"] == [[4, 1], [4, 1], [4, 1]]
      assert_receive {:dice_group, id, entry}, 500
      assert id == game.id
      assert entry.total == 6
      send(tool, :reply)
      assert_receive {:narration_ready, _}, 2_000
      assert [%{"values" => [feedback]}] = Game.world(pid).actor_checkpoint["tools"]
      assert feedback =~ "6"
      assert length(dice_events(game.id)) == 1
      refute_receive {:dice_group, _, _}, 20
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  for mode <- [:restart, :kill] do
    test "#{mode} before committing discards prepared dice and preserves resources" do
      {game, pid, before} = prepared_spell()
      Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
      assert :ok == Game.resume(pid)
      assert_receive {:spell_prepared, tool}, 2_000

      try do
        assert :ok == Game.pause(pid)
        assert Game.world(pid) == before
        assert dice_events(game.id) == []
        model = %Test{script: [cast_call(), narration("Invoco los proyectiles.")]}

        reopened =
          if unquote(mode) == :restart do
            {:ok, reopened} = Game.restart(game.id, model: model, roller: fn _ -> 1 end)
            reopened
          else
            Process.exit(pid, :kill)
            reopened = replacement(game.id, pid)
            assert :ok == Server.set_model(:sys.get_state(reopened).pc_agents["Mara"], model)
            reopened
          end

        assert Games.load_world(Games.get_game(game.id)) == before
        assert dice_events(game.id) == []
        refute_receive {:dice_group, _, _}, 20

        assert :ok ==
                 Server.set_model(:sys.get_state(reopened).dm, %Dragonex.Test.Narrator{
                   text: "Thane, ¿qué haces?"
                 })

        assert :ok == Game.resume(reopened)
        assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
        assert :ok == Game.pause(reopened)
        assert Game.world(reopened).spell_slots["Mara"][1] == 1
        assert Game.world(reopened).characters["Goblin"].hp == 14
        assert length(dice_events(game.id)) == 1
        assert_receive {:dice_group, _, _}, 500
        refute_receive {:dice_group, _, _}, 20
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
        if Process.alive?(tool), do: Process.exit(tool, :kill)
      end
    end
  end

  test "a rejected change never publishes its prepared dice" do
    {game, pid, before} = prepared_spell(reject: true)
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert :ok == Game.resume(pid)
    assert_receive {:spell_prepared, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      send(tool, :commit)
      assert_receive {:spell_outcome, {:error, :rejected}, _ctx}, 2_000
      send(tool, :reply)
      assert_receive {:narration_ready, _}, 2_000
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert dice_events(game.id) == []
      refute_receive {:dice_group, _, _}, 20
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "an SQL failure rolls back the effect, receipt and dice before Session publication" do
    {game, pid, before} = prepared_spell()
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert :ok == Game.resume(pid)
    assert_receive {:spell_prepared, tool}, 2_000
    assert :ok == Game.pause(pid)

    # Real Postgres rejects this table's dice insert after the candidate update.
    # Sandbox owns this temporary constraint and rolls it back after the test.
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_tool_dice CHECK (game_id <> #{game.id} OR type <> 'dice')",
      []
    )

    try do
      send(tool, :commit)
      assert_receive {:spell_outcome, {:error, :persistence_failed}, ctx}, 2_000
      assert Process.alive?(pid)
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert dice_events(game.id) == []
      refute_receive {:dice_group, _, _}, 20

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE game_events DROP CONSTRAINT reject_test_tool_dice",
        []
      )

      # The exact prepared change can now be committed once, without rerolling.
      assert {:ok, _} = Game.commit_rule_change(pid, ctx.deps, ctx.deps.test_change)
      assert Game.world(pid).spell_slots["Mara"][1] == 1
      assert Game.world(pid).characters["Goblin"].hp == 14
      assert length(dice_events(game.id)) == 1
      assert_receive {:dice_group, _, _}, 500
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  test "prepared concentration saves commit with their damage" do
    {game, pid, _before} = prepared_spell(concentrating: "bless")
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert :ok == Game.resume(pid)
    assert_receive {:spell_prepared, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      assert dice_events(game.id) == []
      send(tool, :commit)
      assert_receive {:spell_outcome, {:ok, _}, _ctx}, 2_000
      paid = Game.world(pid)
      assert paid.characters["Goblin"].hp == 14
      assert paid.characters["Goblin"].concentrating == nil
      assert length(dice_events(game.id)) == 2
      assert_receive {:dice_group, _, %{kind: :spell}}, 500
      assert_receive {:dice_group, _, %{kind: :save}}, 500
      refute_receive {:dice_group, _, _}, 20
      assert Games.load_world(Games.get_game(game.id)) == paid
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  test "a concentration save inside the Game change joins the same commit without deadlocking" do
    {game, pid, before} = prepared_spell(during_change: "bless")
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert :ok == Game.resume(pid)
    assert_receive {:spell_prepared, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      assert Game.world(pid) == before
      assert dice_events(game.id) == []
      send(tool, :commit)
      assert_receive {:spell_outcome, {:ok, _}, _ctx}, 2_000
      paid = Game.world(pid)
      assert paid.characters["Goblin"].hp == 14
      assert paid.characters["Thane"].hp == 11
      assert paid.characters["Thane"].concentrating == nil
      assert paid.spell_slots["Mara"][1] == 1
      assert length(dice_events(game.id)) == 2
      assert_receive {:dice_group, _, %{who: "Mara", kind: :spell}}, 500
      assert_receive {:dice_group, _, %{who: "Thane", kind: :save}}, 500
      assert Games.load_world(Games.get_game(game.id)) == paid
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  test "dice without a World effect are saved with their result and recovered only once" do
    {game, pid, before} = prepared_spell(action: :roll)
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert :ok == Game.resume(pid)
    assert_receive {:spell_prepared, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      assert dice_events(game.id) == []
      send(tool, :commit)
      assert_receive {:spell_outcome, {:ok, message}, _ctx}, 2_000
      assert message =~ "2d6 = 2"
      refute_receive {:dice_group, _, _}, 20
      send(tool, :reply)
      assert_receive {:narration_ready, _}, 2_000
      saved = Game.world(pid)
      assert Map.delete(saved, :actor_checkpoint) == Map.delete(before, :actor_checkpoint)
      clean_message = Dragonex.Text.scrub(message)

      assert [%{"name" => "roll_dice", "values" => [^clean_message]}] =
               saved.actor_checkpoint["tools"]

      assert Games.load_world(Games.get_game(game.id)) == saved
      assert [event] = dice_events(game.id)
      assert event.payload["dice"] == [[6, 1], [6, 1]]
      assert_receive {:dice_group, _, %{kind: :roll}}, 500

      {:ok, reopened} =
        Game.restart(game.id,
          model: %Test{script: [roll_call(), narration("Observo los dados.")]},
          roller: fn _ -> 1 end
        )

      assert :ok ==
               Server.set_model(
                 :sys.get_state(reopened).pc_agents["Mara"],
                 %Dragonex.Test.Narrator{
                   text: "Observo los dados."
                 }
               )

      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)
      assert length(dice_events(game.id)) == 1
      refute_receive {:dice_group, _, _}, 20
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  defp prepared_spell(opts \\ []) do
    caster =
      Character.new(
        name: "Mara",
        class: "wizard",
        side: "pc",
        hp: 8,
        max_hp: 8,
        int: 16,
        spells: [Spells.to_character_spell(Spells.get("magic missile"), :int)]
      )

    human =
      Character.new(
        name: "Thane",
        class: "fighter",
        hp: 12,
        max_hp: 12,
        concentrating: opts[:during_change]
      )

    enemy =
      Character.new(
        name: "Goblin",
        side: "enemy",
        hp: 20,
        max_hp: 20,
        concentrating: opts[:concentrating]
      )

    {:ok, game} =
      Games.create_game(
        title: "Una tirada todavía sin efecto",
        roster: [{caster, :ai}, {human, :human}, {enemy, :ai}]
      )

    before = Games.load_world(game)
    actor = if opts[:action] == :roll, do: "dm", else: "Mara"
    {:ok, _} = Games.save_state(game.id, before, actor, before.round, :paused)

    parent = self()

    model = %Test{
      script: [
        if(opts[:action] == :roll, do: roll_call(), else: cast_call()),
        fn _, _ ->
          send(parent, {:narration_ready, self()})
          receive do: (:finish -> narration("Invoco los proyectiles."))
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        roller: fn _ -> 1 end
      )

    state = :sys.get_state(pid)

    if actor == "dm" do
      assert :ok ==
               Server.set_model(state.pc_agents["Mara"], %Dragonex.Test.Narrator{
                 text: "Observo los dados."
               })
    else
      assert :ok ==
               Server.set_model(state.dm, %Dragonex.Test.Narrator{text: "Thane, ¿qué haces?"})
    end

    name = if opts[:action] == :roll, do: "roll_dice", else: "cast_spell"
    raw = Enum.find(Tools.tools(), &(&1.name == name))
    schema = Enum.find(Tools.agent_tools(), &(&1.name == name)).parameters_json_schema
    raw = %{raw | parameters_json_schema: schema}

    prepared =
      ToolReplay.wrap(%{
        raw
        | call: fn ctx, args ->
            world = SharedState.read(ctx.deps.state)

            {message, change} =
              if opts[:action] == :roll do
                {:ok, message} = raw.call.(ctx, args)
                {message, nil}
              else
                {:ok, message, change} =
                  Actions.spell(
                    world,
                    args["caster"],
                    args["spell"],
                    args["target"],
                    ctx.deps.roller,
                    ctx.deps.roll_log
                  )

                {message, change}
              end

            change =
              if opts[:during_change] do
                fn current ->
                  with {:ok, next} <- change.(current),
                       do:
                         Dragonex.World.apply_damage("Thane", 1, "force", ctx.deps.roller,
                           roll_log: ctx.deps.roll_log
                         ).(next)
                end
              else
                change
              end

            send(parent, {:spell_prepared, self()})

            receive do
              :commit ->
                change = if opts[:reject], do: fn _ -> {:error, :rejected} end, else: change

                result =
                  if is_nil(change) do
                    {:ok, message}
                  else
                    with {:ok, _} <-
                           Game.commit_rule_change(ctx.deps.game_owner, ctx.deps, change),
                         do: {:ok, message}
                  end

                send(
                  parent,
                  {:spell_outcome, result, %{ctx | deps: Map.put(ctx.deps, :test_change, change)}}
                )

                receive do
                  :reply ->
                    if result == {:error, :rejected} do
                      raise ExAgent.ModelRetry, "Cambio rechazado sin publicar dados."
                    else
                      result
                    end
                end
            end
          end
      })

    agent = if actor == "dm", do: state.dm, else: state.pc_agents["Mara"]

    :sys.replace_state(agent, fn server ->
      tools = Enum.map(server.agent.tools, &if(&1.name == name, do: prepared, else: &1))
      %{server | agent: %{server.agent | tools: tools}}
    end)

    {game, pid, before}
  end

  defp cast_call do
    tool_calls([
      call("cast_spell", %{"caster" => "Mara", "spell" => "magic missile", "target" => "Goblin"})
    ])
  end

  defp dice_events(id), do: Enum.filter(Games.list_events(id), &(&1.type == :dice))

  defp roll_call, do: tool_calls([call("roll_dice", %{"count" => 2, "sides" => 6})])

  defp replacement(id, old, attempts \\ 200)
  defp replacement(_id, _old, 0), do: flunk("Game did not restart")

  defp replacement(id, old, attempts) do
    case Dragonex.Game.Supervisor.whereis(id) do
      pid when is_pid(pid) and pid != old ->
        Game.world(pid)
        pid

      _ ->
        Process.sleep(5)
        replacement(id, old, attempts - 1)
    end
  end
end
