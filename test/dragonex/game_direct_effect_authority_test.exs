defmodule Dragonex.GameDirectEffectAuthorityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Character, Codec, Game, Games}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp heal do
    tool_calls([call("heal", %{"target" => "Mara", "dice" => "1d4"})])
  end

  defp turnmaster do
    %Test{script: [tool_calls([call("give_turn_to", %{"participant" => "Mara"})]), "Listo."]}
  end

  defp scene_model do
    %Test{script: [tool_calls([call("final_result", %{"scene" => "El camino está despejado."})])]}
  end

  defp begin do
    mara = %{
      Archetypes.wizard(name: "Mara")
      | hp: 5,
        conditions: ["poisoned"],
        spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
    }

    {:ok, game} =
      Games.create_game(
        title: "La magia paga sus recursos",
        scene: "El camino está despejado.",
        roster: [{mara, :human}, {Archetypes.wizard(), :ai}]
      )

    before = %{
      Games.load_world(game)
      | scene_refresh_pending: false,
        elapsed_seconds: 40_635,
        spell_slots: %{"Mara" => %{1 => 1}, "Lyra" => %{1 => 2}}
    }

    {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:dm_ready, self()})
      receive do: (:finish -> heal())
    end

    model = %Test{
      script: [
        tool_calls([
          call("heal", %{"target" => "Mara", "dice" => "1d8"}),
          call("grant_temp_hp", %{"who" => "Mara", "amount" => 30}),
          call("apply_condition", %{"target" => "Lyra", "condition" => "stunned"}),
          call("remove_condition", %{"target" => "Mara", "condition" => "poisoned"}),
          call("level_up", %{"target" => "Lyra", "opts" => %{}})
        ]),
        fn messages, _ ->
          feedback =
            for %{parts: parts} <- messages,
                %{tool_name: name, content: content} <- parts,
                name in ~w(heal grant_temp_hp apply_condition remove_condition level_up),
                do: {name, content}

          send(parent, {:human_feedback, feedback})

          tool_calls([
            call("cast_spell", %{"caster" => "Mara", "spell" => "false life", "target" => "Mara"})
          ])
        end,
        narration("Mara lanza su protección mágica y espera la respuesta del mundo."),
        blocked,
        narration("Una curación establecida devuelve algo de fuerza.")
      ]
    }

    roller = fn sides ->
      assert sides == 4
      send(parent, {:native_roll, sides})
      4
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        scene_model: scene_model(),
        turnmaster_model: turnmaster(),
        roller: roller
      )

    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(pid, "Mara", "Lanzo False Life sobre mí y espero su resultado.")

    {game, pid, before, roller}
  end

  defp before_confirmation(game, pid, before) do
    assert_receive {:human_feedback, feedback}, 2_000

    assert Enum.sort(Enum.map(feedback, &elem(&1, 0))) ==
             ~w(apply_condition grant_temp_hp heal level_up remove_condition)

    assert Enum.all?(feedback, &(inspect(elem(&1, 1)) =~ "RECHAZADO — solo el DM"))
    assert_receive {:dm_ready, request}, 2_000
    assert_receive {:native_roll, 4}
    refute_receive {:native_roll, _}, 20
    assert Game.current(pid) == "dm"
    world = Game.world(pid)
    assert world.characters["Mara"].hp == 5
    assert world.characters["Mara"].temp_hp == 8
    assert Character.condition_names(world.characters["Mara"]) == ["poisoned"]
    assert world.characters["Lyra"] == before.characters["Lyra"]
    assert world.spell_slots == %{"Mara" => %{1 => 0}, "Lyra" => %{1 => 2}}
    assert world.effect_expiries["Mara"]["temp_hp"] == 44_235
    assert world.elapsed_seconds == before.elapsed_seconds
    assert Games.load_world(Games.get_game(game.id)) == world
    assert length(Enum.filter(Games.list_events(game.id), &(&1.type == :dice))) == 1
    request
  end

  defp finish(game, pid, before) do
    assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    world = Game.world(pid)
    assert world.characters["Mara"].hp == min(9, before.characters["Mara"].max_hp)
    assert world.characters["Mara"].temp_hp == 8
    assert Character.condition_names(world.characters["Mara"]) == ["poisoned"]
    assert world.characters["Lyra"] == before.characters["Lyra"]
    assert world.spell_slots == %{"Mara" => %{1 => 0}, "Lyra" => %{1 => 2}}
    assert world.effect_expiries["Mara"]["temp_hp"] == 44_235
    assert world.elapsed_seconds == before.elapsed_seconds
    assert world.actor_checkpoint == nil
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Codec.decode(Codec.encode(world)) == world
    assert_receive {:native_roll, 4}
    refute_receive {:native_roll, _}, 20
    events = Games.list_events(game.id)
    dice = Enum.filter(events, &(&1.type == :dice))
    assert Enum.map(dice, & &1.payload["kind"]) == ["spell", "heal"]
    assert Enum.all?(dice, &(&1.payload["dice"] == [[4, 4]]))
    assert Enum.count(events, &(&1.type == :action)) == 1
  end

  for mode <- [:continue, :restart] do
    test "#{mode}: direct effects are rejected and a paid spell survives before DM healing" do
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
                       model: %Test{
                         script: [heal(), narration("Una curación establecida devuelve fuerzas.")]
                       },
                       scene_model: scene_model(),
                       turnmaster_model: turnmaster(),
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
