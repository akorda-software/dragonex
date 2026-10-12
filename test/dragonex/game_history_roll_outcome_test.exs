defmodule Dragonex.GameHistoryRollOutcomeTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Actions, Archetypes, Game, Games, Monsters, RollLog}
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "both response agents receive an old confirmed critical and reopening never rerolls it" do
    {:ok, game} =
      Games.create_game(
        title: "Recordar el resultado del combate",
        scene: "La taberna permanece en calma.",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai},
          {Monsters.goblin(), :ai}
        ]
      )

    initial = Games.load_world(game)

    roller = fn
      20 -> 20
      _ -> 4
    end

    {:ok, recorder} = RollLog.start()

    {rolls, before} =
      try do
        log = %RollLog{base: roller, recorder: recorder}

        {:ok, _, change} =
          Actions.attack(initial, "Thane", "goblin", "longsword", roller, :normal, log)

        {:ok, world} = change.(initial)
        {RollLog.entries(recorder), world}
      after
        RollLog.stop(recorder)
      end

    assert before.characters["goblin"].hp == 0
    assert Enum.all?(rolls, &(&1.outcome == :crit))
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    for roll <- rolls, do: Games.append_event(game.id, :dice, "Thane", "all", roll)

    for index <- 1..18 do
      actor = if rem(index, 2) == 0, do: "Lyra", else: "Vex"

      {:ok, _} =
        Games.append_event(game.id, :narration, actor, "all", %{
          text: String.duplicate("La taberna permanece tranquila. ", 10) <> "Detalle #{index}."
        })
    end

    historical = Games.list_events(game.id)
    parent = self()

    unused_tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :history_tm_requested)
          "listo"
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [narration("—¿Qué recordáis?"), narration("Thane, ¿qué decides hacer?")]
            },
            turnmaster_model: unused_tm
          ]}}
      )

    state = :sys.get_state(pid)

    for actor <- ["Lyra", "Vex"] do
      response = fn messages, _ ->
        send(parent, {:remembered_critical, actor, ModelMessages.project(messages)})
        narration("—Recuerdo el golpe de Thane.")
      end

      assert :ok == Server.set_model(state.pc_agents[actor], %Test{script: [response]})
    end

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))

    assert {:ok, :resolving} ==
             Game.declare(pid, "Thane", "Lyra, Vex, ¿qué recordáis del combate?")

    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)

    for actor <- ["Lyra", "Vex"] do
      assert_receive {:remembered_critical, ^actor, wire}

      dice =
        for m <- wire,
            m["role"] == "user" and String.starts_with?(m["content"], "[🎲 "),
            do: m["content"]

      assert length(dice) == 2
      assert Enum.all?(dice, &String.ends_with?(&1, "→ ¡CRÍTICO!"))
      assert hd(dice) =~ "d20:20 +5 = 25 vs CA 15"
      assert List.last(dice) =~ "d8:4 d8:4 +3 = 11"
      assert Enum.any?(wire, &(&1["role"] == "system" and &1["content"] =~ "Eres #{actor},"))
      assert Enum.all?(wire, &String.valid?(&1["content"] || ""))
    end

    refute_received :history_tm_requested
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    events = Games.list_events(game.id)
    assert Enum.take(events, length(historical)) == historical
    new_events = Enum.drop(events, length(historical))

    assert Enum.map(Enum.filter(new_events, &(&1.type == :narration)), & &1.actor) ==
             ["Thane", "Lyra", "Vex"]

    refute Enum.any?(new_events, &(&1.type == :dice))

    assert :ok == stop_supervised({Game, game.id})
    assert {:ok, reopened} = Game.restart(game.id, model: %Test{label: "No debe resolver nada."})
    assert reopened != pid
    assert :ok == Game.resume(reopened)
    assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(reopened)
    assert Game.world(reopened) == before
    assert Games.list_events(game.id) == events
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end
end
