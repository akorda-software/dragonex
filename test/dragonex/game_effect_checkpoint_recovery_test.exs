defmodule Dragonex.GameEffectCheckpointRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Character, Game, Games, Tools}
  alias Dragonex.Game.ToolReplay
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server}
  import Dragonex.Test.Harness

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for mode <- [:restart, :kill] do
    test "#{mode} between the committed effect and the tool reply does not spend it twice" do
      {game, pid, cast} = pending_effect()
      assert :ok == Game.resume(pid)
      assert_receive {:effect_committed, tool}, 2_000

      try do
        assert :ok == Game.pause(pid)
        paid = Game.world(pid)
        assert paid.spell_slots["Mara"][1] == 1
        assert paid.characters["Goblin"].hp == 14
        assert Games.load_world(Games.get_game(game.id)) == paid
        assert [%{"values" => [receipt]}] = paid.actor_checkpoint["tools"]
        assert receipt =~ "ya aplicó su cambio"

        model = %Test{script: [cast, narration("Invoco los proyectiles.")]}

        reopened =
          if unquote(mode) == :restart do
            {:ok, reopened} = Game.restart(game.id, model: model, roller: fn _ -> 1 end)
            reopened
          else
            Process.exit(pid, :kill)
            reopened = replacement(game.id, pid)
            state = :sys.get_state(reopened)
            assert :ok == Server.set_model(state.pc_agents["Mara"], model)
            reopened
          end

        state = :sys.get_state(reopened)

        assert :ok ==
                 Server.set_model(state.dm, %Dragonex.Test.Narrator{text: "Thane, ¿qué haces?"})

        assert :ok == Game.resume(reopened)
        assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
        assert :ok == Game.pause(reopened)
        final = Game.world(reopened)
        assert final.spell_slots["Mara"][1] == 1
        assert final.characters["Goblin"].hp == 14
        assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
        assert final.actor_checkpoint == nil
        assert Games.load_world(Games.get_game(game.id)) == final
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
        if Process.alive?(tool), do: Process.exit(tool, :kill)
      end
    end
  end

  test "the completed tool replaces its receipt with one precise result" do
    {game, pid, _cast} = pending_effect()
    assert :ok == Game.resume(pid)
    assert_receive {:effect_committed, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      send(tool, :complete)
      assert_receive {:tool_reply_recorded, _}, 2_000
      world = Game.world(pid)
      assert [%{"values" => [feedback]}] = world.actor_checkpoint["tools"]
      assert feedback =~ "6"
      refute feedback =~ "ya aplicó su cambio"
      assert :sys.get_state(pid).busy.tool_commits == %{}
      assert Games.load_world(Games.get_game(game.id)) == world
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "several changes from one tool reserve only one replay result" do
    {game, pid, cast} = pending_effect(calls: 2)
    assert :ok == Game.resume(pid)
    assert_receive {:effect_committed, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      paid = Game.world(pid)
      assert paid.spell_slots["Mara"][1] == 0
      assert paid.characters["Goblin"].hp == 8
      assert [%{"values" => [_]}] = paid.actor_checkpoint["tools"]
      parent = self()

      model = %Test{
        script: [
          cast,
          fn messages, _ ->
            send(parent, {:receipt_context, messages})
            narration("Invoco los proyectiles.")
          end
        ]
      }

      {:ok, reopened} = Game.restart(game.id, model: model, roller: fn _ -> 1 end)
      state = :sys.get_state(reopened)

      assert :ok ==
               Server.set_model(state.dm, %Dragonex.Test.Narrator{text: "Thane, ¿qué haces?"})

      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)
      final = Game.world(reopened)
      assert final.spell_slots["Mara"][1] == 0
      assert final.characters["Goblin"].hp == 8
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2
      assert_receive {:receipt_context, messages}
      assert inspect(messages, limit: :infinity) =~ "Resultado ya aplicado antes del fallo"
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  test "a rejected tool does not reserve an effect that can block a corrected call" do
    {game, pid, _cast} = pending_effect(target: "Nobody")
    assert :ok == Game.resume(pid)
    assert_receive {:effect_committed, tool}, 2_000

    try do
      assert :ok == Game.pause(pid)
      assert Game.world(pid).actor_checkpoint == nil
      assert :sys.get_state(pid).busy.tool_commits == %{}

      cast =
        tool_calls([
          call("cast_spell", %{
            "caster" => "Mara",
            "spell" => "magic missile",
            "target" => "Goblin"
          })
        ])

      {:ok, reopened} =
        Game.restart(game.id,
          model: %Test{script: [cast, narration("Invoco los proyectiles.")]},
          roller: fn _ -> 1 end
        )

      assert :ok ==
               Server.set_model(:sys.get_state(reopened).dm, %Dragonex.Test.Narrator{
                 text: "Thane, ¿qué haces?"
               })

      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)
      assert Game.world(reopened).spell_slots["Mara"][1] == 1
      assert Game.world(reopened).characters["Goblin"].hp == 14
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  defp pending_effect(opts \\ []) do
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

    human = Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12)
    enemy = Character.new(name: "Goblin", side: "enemy", hp: 20, max_hp: 20)

    {:ok, game} =
      Games.create_game(
        title: "Un efecto guardado antes de responder",
        roster: [{caster, :ai}, {human, :human}, {enemy, :ai}]
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Mara", world.round, :paused)

    cast =
      tool_calls([
        call("cast_spell", %{
          "caster" => "Mara",
          "spell" => "magic missile",
          "target" => Keyword.get(opts, :target, "Goblin")
        })
      ])

    parent = self()

    model = %Test{
      script: [
        cast,
        fn _, _ ->
          send(parent, {:tool_reply_recorded, self()})
          receive do: (:complete -> narration("Invoco los proyectiles."))
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        roller: fn _ -> 1 end
      )

    state = :sys.get_state(pid)
    assert :ok == Server.set_model(state.dm, %Dragonex.Test.Narrator{text: "Thane, ¿qué haces?"})
    raw = Enum.find(Tools.tools(), &(&1.name == "cast_spell"))
    schema = Enum.find(Tools.agent_tools(), &(&1.name == "cast_spell")).parameters_json_schema
    raw = %{raw | parameters_json_schema: schema}

    blocked =
      ToolReplay.wrap(%{
        raw
        | call: fn ctx, args ->
            result =
              Enum.reduce(1..Keyword.get(opts, :calls, 1), nil, fn _, _ ->
                raw.call.(ctx, args)
              end)

            send(parent, {:effect_committed, self()})
            receive do: (:complete -> result)
          end
      })

    :sys.replace_state(state.pc_agents["Mara"], fn server ->
      tools = Enum.map(server.agent.tools, &if(&1.name == "cast_spell", do: blocked, else: &1))
      %{server | agent: %{server.agent | tools: tools}}
    end)

    {game, pid, cast}
  end

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
