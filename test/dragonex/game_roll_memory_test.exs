defmodule Dragonex.GameRollMemoryTest do
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

  defp observe(actor, text) do
    parent = self()

    fn messages, _ ->
      send(parent, {:archive_request, actor, ModelMessages.project(messages)})
      narration(text)
    end
  end

  defp boot(model) do
    {:ok, game} =
      Games.create_game(
        title: "Recordar combate fuera de ventana",
        scene: "La taberna sigue en calma.",
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
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    for roll <- rolls, do: Games.append_event(game.id, :dice, "Thane", "all", roll)

    Games.append_event(game.id, :dice, "dm", "dm", %{
      reason: "PrivateArchiveMarker",
      dice: [[20, 10]],
      total: 10
    })

    for n <- 1..410,
        do:
          Games.append_event(game.id, :system, "system", "all", %{note: "Crónica posterior #{n}"})

    historical = Games.list_events(game.id)
    refute Enum.any?(Games.recent_events(game.id, 400), &(&1.type == :dice))
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :archive_tm_request)
          "(no decision)"
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model, turnmaster_model: tm)
    install_pcs(pid)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before, historical}
  end

  defp install_pcs(pid) do
    for {actor, server} <- :sys.get_state(pid).pc_agents,
        do:
          assert(
            :ok ==
              Server.set_model(server, %Test{
                script: [observe(actor, "—Recuerdo el crítico de Thane.")]
              })
          )
  end

  defp assert_archive(messages, actor) do
    archives = Enum.filter(messages, &String.contains?(&1["content"], "ARCHIVO DE TIRADAS"))
    assert length(archives) == 1
    [archive] = archives
    assert archive["role"] == "user"
    text = archive["content"]
    assert text =~ "WORLD:"
    assert text =~ "ataque a goblin con espada larga d20:20 +5 = 25 vs CA 15 → ¡CRÍTICO!"
    assert text =~ "d8:4 d8:4 +3 = 11 → ¡CRÍTICO!"
    assert text =~ "no son acciones pendientes"

    if actor == "dm",
      do: assert(text =~ "PrivateArchiveMarker"),
      else: refute(text =~ "PrivateArchiveMarker")

    assert Enum.any?(messages, &(&1["content"] =~ "Crónica posterior"))
    assert [%{"role" => "system", "content" => role} | _] = messages

    assert role =~
             if(actor in ["Thane", "dm"], do: "Eres el Dungeon Master", else: "Eres #{actor},")

    assert Enum.all?(messages, &String.valid?(&1["content"]))
    Jason.encode!(messages)
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  defp conserved(game, pid, before, historical, actors) do
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    events = Games.list_events(game.id)
    assert Enum.take(events, length(historical)) == historical
    new = Enum.drop(events, length(historical))
    assert Enum.map(Enum.filter(new, &(&1.type == :narration)), & &1.actor) == actors
    refute Enum.any?(new, &(&1.type == :dice))
    refute_received :archive_tm_request
  end

  test "human, both PCs and the DM receive old engine outcomes with their own visibility and current World" do
    model = %Test{
      script: [
        observe("Thane", "—Lyra, Vex, ¿qué preferís, y qué puede confirmar la posadera?"),
        observe("dm", "La posadera confirma el relato.")
      ]
    }

    {game, pid, before, historical} = boot(model)

    try do
      assert {:ok, :resolving} ==
               Game.declare(
                 pid,
                 "Thane",
                 "Lyra, Vex, ¿qué preferís, y qué puede confirmar la posadera? Añado que sigo aquí."
               )

      finish(pid)

      for actor <- ["Thane", "Lyra", "Vex", "dm"] do
        assert_receive {:archive_request, ^actor, messages}
        assert_archive(messages, actor)
      end

      conserved(game, pid, before, historical, ["Thane", "Lyra", "Vex", "dm"])
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a PC pending at restart recovers the same old rolls without rerolling or replaying human speech" do
    {game, pid, before, historical} = boot(%Test{script: [observe("dm", "No debe narrar.")]})
    parent = self()

    blocked = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:archive_blocked, self(), ModelMessages.project(messages)})
          receive do: (:finish -> narration("—Recuerdo la espada."))
        end
      ]
    }

    try do
      assert :ok == Server.set_model(:sys.get_state(pid).pc_agents["Lyra"], blocked)

      assert {:ok, :resolving} ==
               Game.declare(pid, "Thane", "Lyra, Vex, ¿qué recordáis del combate?")

      assert_receive {:archive_blocked, run, messages}, 2_000
      assert_archive(messages, "Lyra")
      assert :ok == Game.pause(pid)
      pending = Game.world(pid)
      ref = Process.monitor(run)

      assert {:ok, fresh} =
               Game.restart(game.id, model: %Test{script: [observe("dm", "No debe narrar.")]})

      assert fresh != pid
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == pending
      install_pcs(fresh)
      assert :ok == Game.resume(fresh)
      finish(fresh)

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:archive_request, ^actor, resumed}
        assert_archive(resumed, actor)
      end

      refute_received {:archive_request, "dm", _}
      conserved(game, fresh, before, historical, ["Thane", "Lyra", "Vex"])
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
