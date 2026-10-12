defmodule Dragonex.GameWorldRefreshTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Monsters}
  alias Dragonex.Test.ModelMessages
  alias ExAgent.Models.Test

  @prefix "WORLD VIGENTE:"

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for actor <- ["Thane", "Vex"] do
    test "#{actor} sees the defeated enemy before finishing the same beat" do
      actor = unquote(actor)
      companions = if actor == "Vex", do: [{Archetypes.rogue(), :ai}], else: []

      {:ok, game} =
        Games.create_game(
          title: "El resultado manda en la continuación",
          roster:
            [{Archetypes.fighter(), :human} | companions] ++ [{Monsters.goblin(name: "g1"), :ai}],
          initiative: Enum.uniq([actor, "Thane", "g1"])
        )

      world = Games.load_world(game)
      world = put_in(world.characters["g1"].hp, 1)
      {:ok, _} = Games.save_state(game.id, world, actor, world.round, :paused)
      owner = self()
      weapon = if actor == "Thane", do: "longsword", else: "shortsword"

      model = %Test{
        script: [
          fn messages, _ ->
            user =
              ModelMessages.project(messages)
              |> Enum.filter(&(&1["role"] == "user"))
              |> List.last()

            if String.contains?(user["content"], "Es el turno de #{actor} (") and
                 String.contains?(user["content"], "Combate -- ronda") do
              send(owner, {:attack_start, messages})

              tool_calls([
                call("make_attack", %{"attacker" => actor, "target" => "g1", "weapon" => weapon})
              ])
            else
              narration("El combate ha terminado.")
            end
          end,
          fn messages, _ ->
            fresh =
              ModelMessages.project(messages)
              |> Enum.filter(
                &(&1["role"] == "system" and String.starts_with?(&1["content"], @prefix))
              )

            send(owner, {:attack_continuation, fresh})

            if Enum.any?(
                 fresh,
                 &String.contains?(&1["content"], "No hay enemigos presentes con PG positivos")
               ),
               do: narration("El goblin cae y no queda ningún enemigo en pie."),
               else: narration("¡Remátalo, sigue en pie!")
          end
        ]
      }

      tm = %Test{
        script: [tool_calls([call("give_turn_to", %{"participant" => "Thane"})]), "listo"]
      }

      rolls = start_supervised!({Agent, fn -> [] end})

      roller = fn sides ->
        Agent.update(rolls, &(&1 ++ [sides]))
        if sides == 20, do: 15, else: 1
      end

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game,
           {game.id,
            [
              model: model,
              scene_model: %Test{label: "Sin cambios de escena."},
              turnmaster_model: tm,
              roller: roller
            ]}}
        )

      assert :ok == Game.resume(pid)

      if actor == "Thane" do
        assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)

        assert {:ok, :resolving} =
                 Game.declare(pid, "Thane", "Ataco al goblin con mi espada larga.")
      end

      assert :ok ==
               Game.await(
                 pid,
                 &(&1.current == "Thane" and &1.status == :waiting and
                     &1.world.phase == :exploration),
                 5_000
               )

      assert :ok == Game.pause(pid)
      assert_receive {:attack_start, first}

      refute Enum.any?(
               ModelMessages.project(first),
               &String.starts_with?(&1["content"] || "", @prefix)
             )

      assert_receive {:attack_continuation, [%{"content" => fresh}]}
      refute_received {:attack_start, _}
      refute_received {:attack_continuation, _}
      assert fresh =~ "0/7 pg" and fresh =~ "No hay enemigos presentes con PG positivos"
      if actor == "Vex", do: assert(fresh =~ "IA, auto-juega")
      after_world = Game.world(pid)
      assert after_world.characters["g1"].hp == 0

      for name <- ["Thane" | Enum.map(companions, fn {c, _} -> c.name end)],
          do: assert(after_world.characters[name] == world.characters[name])

      assert after_world.elapsed_seconds == world.elapsed_seconds
      assert Games.load_world(Games.get_game(game.id)) == after_world
      assert Agent.get(rolls, & &1) == if(actor == "Thane", do: [20, 8], else: [20, 6, 6])
      events = Games.list_events(game.id)

      expected_voice =
        if actor == "Thane",
          do: "Ataco al goblin con mi espada larga.",
          else: "El goblin cae y no queda ningún enemigo en pie."

      assert Enum.count(
               events,
               &(&1.type == :narration and &1.actor == actor and
                   &1.payload["text"] == expected_voice)
             ) == 1

      refute inspect(events, limit: :infinity) =~ @prefix
    end
  end
end
