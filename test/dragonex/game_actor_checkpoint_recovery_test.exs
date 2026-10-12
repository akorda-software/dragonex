defmodule Dragonex.GameActorCheckpointRecoveryTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Character, Codec, Game, Games, World}
  alias Dragonex.Game.{Supervisor, ToolReplay}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for mode <- [:restart, :kill] do
    test "#{mode} after an AI cast retains the resolved action without casting again" do
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
          title: "Una acción IA que continúa",
          roster: [{caster, :ai}, {human, :human}, {enemy, :ai}]
        )

      before = Games.load_world(game)
      {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
      parent = self()

      cast =
        tool_calls([
          call("cast_spell", %{
            "caster" => "Mara",
            "spell" => "magic missile",
            "target" => "Goblin"
          })
        ])

      blocked = %Test{
        script: [
          cast,
          fn _, _ ->
            send(parent, {:cast_applied, self()})
            receive do: (:complete -> narration("Invoco los proyectiles."))
          end
        ]
      }

      {:ok, pid} = Game.ensure_started(game.id, model: blocked, roller: fn _ -> 1 end)
      assert :ok == Game.resume(pid)
      assert_receive {:cast_applied, run}, 2_000

      try do
        paid = Game.world(pid)
        assert paid.spell_slots["Mara"][1] == 1
        assert paid.characters["Goblin"].hp == 14
        assert :ok == Game.pause(pid)

        model = %Test{
          script: [cast, narration("Invoco los proyectiles.")]
        }

        reopened =
          if unquote(mode) == :restart do
            {:ok, reopened} = Game.restart(game.id, model: model, roller: fn _ -> 1 end)
            reopened
          else
            Process.exit(pid, :kill)
            reopened = await_replacement(game.id, pid)
            state = :sys.get_state(reopened)
            assert :ok == Server.set_model(state.pc_agents["Mara"], model)
            reopened
          end

        assert :ok ==
                 Server.set_model(:sys.get_state(reopened).dm, %Dragonex.Test.Narrator{
                   text: "Thane, ¿qué quieres observar?"
                 })

        assert :ok == Game.resume(reopened)
        assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
        assert :ok == Game.pause(reopened)
        world = Game.world(reopened)
        assert world.spell_slots["Mara"][1] == 1
        assert world.characters["Goblin"].hp == 14
        assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
        assert Games.load_world(Games.get_game(game.id)) == world
        assert world.actor_checkpoint == nil

        assert Enum.count(Games.list_events(game.id), &(&1.type == :turn and &1.actor == "Mara")) ==
                 1

        assert [%{payload: %{"text" => "Invoco los proyectiles.", "complete" => true}}] =
                 Enum.filter(
                   Games.list_events(game.id),
                   &(&1.type == :narration and &1.actor == "Mara")
                 )
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
        if Process.alive?(run), do: Process.exit(run, :kill)
      end
    end
  end

  test "Codec retains a pending beat and old worlds default to no checkpoint" do
    saved = %{
      "actor" => "Mara",
      "turn_id" => "pending",
      "phase" => "exploration",
      "mini_turn" => false,
      "enemies_before" => ["Goblin"],
      "tools" => [
        %{
          "name" => "cast_spell",
          "args" => %{"cast_level" => 1},
          "values" => ["Se aplican seis puntos de daño."]
        }
      ]
    }

    world = %{World.new() | actor_checkpoint: saved}
    decoded = world |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert decoded == world
    assert ToolReplay.restore(decoded, "Mara").turn_id == "pending"
    assert ToolReplay.restore(decoded, "Thane") == nil

    assert Codec.decode(Map.delete(Codec.encode(world), "actor_checkpoint")).actor_checkpoint ==
             nil
  end

  test "malformed checkpoint entries do not become replay instructions" do
    for saved <- [
          %{},
          %{"actor" => "Mara"},
          %{
            "actor" => "Mara",
            "turn_id" => "bad",
            "phase" => "combat",
            "mini_turn" => false,
            "enemies_before" => [],
            "tools" => [%{"name" => "cast_spell", "args" => %{}, "values" => [123]}]
          }
        ] do
      assert ToolReplay.restore(%{World.new() | actor_checkpoint: saved}, "Mara") == nil
    end
  end

  test "DM recovery preserves the original hostile snapshot and forces initiative only once" do
    human = Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12)
    {:ok, game} = Games.create_game(title: "Un enemigo que continúa", roster: [{human, :human}])
    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    parent = self()
    spawn = tool_calls([call("spawn_monster", %{"kind" => "goblin", "name" => "Goblin"})])

    blocked = %Test{
      script: [
        spawn,
        fn _, _ ->
          send(parent, {:spawn_applied, self()})
          receive do: (:complete -> narration("El goblin sostiene una daga."))
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: blocked, roller: fn _ -> 1 end)
    assert :ok == Game.resume(pid)
    assert_receive {:spawn_applied, run}, 2_000

    try do
      assert :ok == Game.pause(pid)
      saved = Game.world(pid)
      assert saved.phase == :exploration
      assert saved.actor_checkpoint["enemies_before"] == []

      {:ok, reopened} =
        Game.restart(game.id,
          model: %Test{
            script: [
              spawn,
              narration("El goblin sostiene una daga."),
              narration("Thane, ¿qué quieres hacer?")
            ]
          },
          roller: fn _ -> 1 end
        )

      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)
      final = Game.world(reopened)
      assert final.phase == :combat
      assert final.characters["Goblin"].hp == saved.characters["Goblin"].hp
      assert final.actor_checkpoint == nil
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2

      assert Enum.count(
               Games.list_events(game.id),
               &(&1.type == :system and (&1.payload["note"] || "") =~ "toma la iniciativa")
             ) == 1
    after
      Supervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "model text in pending tool arguments is scrubbed before its World checkpoint is saved" do
    human = Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12)
    {:ok, game} = Games.create_game(title: "Una escena saneada", roster: [{human, :human}])
    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    parent = self()

    model = %Test{
      script: [
        tool_calls([
          call("set_scene", %{
            "narration" => "[DM]: La puerta sigue cerrada."
          })
        ]),
        fn _, _ ->
          send(parent, {:scene_saved, self()})
          receive do: (:complete -> narration("Thane, ¿qué quieres observar?"))
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model)
    assert :ok == Game.resume(pid)
    assert_receive {:scene_saved, run}, 2_000

    try do
      saved = Games.load_world(Games.get_game(game.id))
      refute inspect(saved.actor_checkpoint) =~ "[DM]"

      assert saved.actor_checkpoint["tools"] |> hd() |> get_in(["args", "narration"]) ==
               "La puerta sigue cerrada."
    after
      Supervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "a new human declaration after restarting autoplay does not inherit the previous beat" do
    {game, pid, run, cast} = pending_cast(:human)

    try do
      assert :ok == Game.pause(pid)

      {:ok, reopened} =
        Game.restart(game.id,
          model: %Test{
            script: [
              cast,
              narration("Invoco los proyectiles."),
              narration("Mara, ¿qué quieres observar?")
            ]
          },
          roller: fn _ -> 1 end
        )

      assert :ok == Game.resume(reopened)
      assert :ok == Game.await(reopened, &(&1.current == "Mara" and &1.status == :waiting))
      assert Game.world(reopened).actor_checkpoint != nil
      assert {:ok, :resolving} == Game.declare(reopened, "Mara", "Lanzo el hechizo otra vez.")
      assert :ok == Game.await(reopened, &(&1.current == "Mara" and &1.status == :waiting))
      assert :ok == Game.pause(reopened)
      world = Game.world(reopened)
      assert world.spell_slots["Mara"][1] == 0
      assert world.characters["Goblin"].hp == 8
      assert world.actor_checkpoint == nil
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2
    after
      Supervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "a definitive actor failure clears its checkpoint while retaining paid resources" do
    {game, pid, run, _} = pending_cast(:ai, :fail)

    try do
      assert :ok == Game.pause(pid)
      assert Game.world(pid).actor_checkpoint != nil
      send(run, :complete)
      assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
      world = Game.world(pid)
      assert world.actor_checkpoint == nil
      assert world.spell_slots["Mara"][1] == 1
      assert world.characters["Goblin"].hp == 14
      assert Games.load_world(Games.get_game(game.id)) == world
    after
      Supervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  defp pending_cast(kind, completion \\ :narrate) do
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
        title: "Una resolución pendiente",
        roster: [{caster, kind}, {human, :human}, {enemy, :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
    parent = self()

    cast =
      tool_calls([
        call("cast_spell", %{"caster" => "Mara", "spell" => "magic missile", "target" => "Goblin"})
      ])

    model = %Test{
      script: [
        cast,
        fn _, _ ->
          send(parent, {:pending_cast, self()})

          receive do
            :complete ->
              if completion == :fail,
                do: raise("actor fault after resolved tool"),
                else: narration("Invoco los proyectiles.")
          end
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model, roller: fn _ -> 1 end)
    if kind == :human, do: assert(:ok == Game.enable_auto_play(pid, "Mara"))
    assert :ok == Game.resume(pid)
    assert_receive {:pending_cast, run}, 2_000
    {game, pid, run, cast}
  end

  defp await_replacement(game_id, old, attempts \\ 200)
  defp await_replacement(_game_id, _old, 0), do: flunk("Game did not restart")

  defp await_replacement(game_id, old, attempts) do
    case Supervisor.whereis(game_id) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        Process.sleep(5)
        await_replacement(game_id, old, attempts - 1)
    end
  end
end
