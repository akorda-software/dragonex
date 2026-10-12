defmodule Dragonex.GameCombatAuthorityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp spawn do
    tool_calls([call("spawn_monster", %{"kind" => "goblin", "name" => "Goblin"})])
  end

  defp begin do
    {:ok, game} =
      Games.create_game(
        title: "El jugador no crea su propio combate",
        scene: "El camino está despejado.",
        roster: [{Archetypes.fighter(name: "Mara"), :human}]
      )

    before = %{Games.load_world(game) | scene_refresh_pending: false, elapsed_seconds: 40_635}
    {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:dm_ready, self()})
      receive do: (:finish -> spawn())
    end

    model = %Test{
      script: [
        tool_calls([
          call("spawn_monster", %{"kind" => "goblin", "name" => "Invasor"}),
          call("roll_initiative", %{}),
          call("end_combat", %{})
        ]),
        fn messages, _ ->
          feedback =
            for %{parts: parts} <- messages,
                %{tool_name: name, content: content} <- parts,
                name in ["spawn_monster", "roll_initiative", "end_combat"],
                do: {name, content}

          send(parent, {:human_feedback, feedback})
          narration("Mara aguarda la respuesta del mundo.")
        end,
        blocked,
        narration("Un goblin cierra el camino.")
      ]
    }

    # Actions.initiative rolls in canonical name order: Goblin, then Mara.
    dice = start_supervised!({Agent, fn -> [1, 20] end})

    roller = fn sides ->
      send(parent, {:native_initiative, sides})
      Agent.get_and_update(dice, fn [n | rest] -> {n, rest} end)
    end

    {:ok, pid} = Game.ensure_started(game.id, model: model, roller: roller)
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(pid, "Mara", "Busco un enemigo y espero la respuesta del mundo.")

    {game, pid, before, roller}
  end

  defp before_confirmation(game, pid, before) do
    assert_receive {:human_feedback, feedback}, 2_000

    assert Enum.sort(Enum.map(feedback, &elem(&1, 0))) ==
             ["end_combat", "roll_initiative", "spawn_monster"]

    assert Enum.all?(feedback, &(inspect(elem(&1, 1)) =~ "RECHAZADO — solo el DM"))
    assert_receive {:dm_ready, request}, 2_000
    refute_receive {:native_initiative, _}, 20
    assert Game.current(pid) == "dm"
    keys = Map.keys(Map.from_struct(before)) -- [:actor_checkpoint, :pending_turn]
    assert Map.take(Game.world(pid), keys) == Map.take(before, keys)
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    request
  end

  defp finish(game, pid, before) do
    assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    world = Game.world(pid)
    assert world.phase == :combat
    assert world.initiative_order == ["Mara", "Goblin"]
    assert world.current_combatant == "Mara"
    assert world.characters["Mara"] == before.characters["Mara"]
    refute Map.has_key?(world.characters, "Invasor")
    assert world.characters["Goblin"].hp == 7
    assert world.elapsed_seconds == before.elapsed_seconds
    assert world.actor_checkpoint == nil
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Codec.decode(Codec.encode(world)) == world
    assert_receive {:native_initiative, 20}
    assert_receive {:native_initiative, 20}
    refute_receive {:native_initiative, _}, 20
    events = Games.list_events(game.id)
    dice = Enum.filter(events, &(&1.type == :dice))
    assert Enum.map(dice, & &1.payload["who"]) == ["Goblin", "Mara"]
    assert Enum.map(dice, & &1.payload["dice"]) == [[[20, 1]], [[20, 20]]]
    assert Enum.all?(dice, &(&1.payload["timing"] == "forced_initiative"))
    assert Enum.count(events, &(&1.type == :action)) == 1
  end

  for mode <- [:continue, :restart] do
    test "#{mode}: rejected human world tools do not create dice; DM spawn still forces initiative" do
      {game, pid, before, roller} = begin()

      try do
        request = before_confirmation(game, pid, before)

        pid =
          if unquote(mode) == :restart do
            monitor = Process.monitor(request)
            assert :ok = Game.pause(pid)
            paid = Game.world(pid)

            assert {:ok, fresh} =
                     Game.restart(game.id,
                       model: %Test{script: [spawn(), narration("Un goblin cierra el camino.")]},
                       roller: roller
                     )

            assert_receive {:DOWN, ^monitor, :process, ^request, _}, 1_000
            assert Game.world(fresh) == paid
            assert :ok = Game.resume(fresh)
            fresh
          else
            send(request, :finish)
            pid
          end

        finish(game, pid, before)
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end
end
