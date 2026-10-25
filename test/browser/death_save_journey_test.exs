defmodule DragonexWeb.Browser.DeathSaveJourneyTest do
  use ExUnit.Case, async: false

  @moduletag browser: true, capture_log: true
  @moduletag timeout: 120_000

  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Archetypes, Character, Game, Games, World}
  alias ExAgent.Models.Test

  @declaration "Intento salvarme y recuperar el aliento."

  test "a browser recovers a downed human across paid-save failure, reload and restart" do
    Dragonex.Test.Sandbox.start_shared!()
    python = System.find_executable("python3") || flunk("Install Python Playwright and Chromium")

    artifacts =
      System.get_env("DRAGONEX_BROWSER_ARTIFACTS") ||
        Path.join(
          System.tmp_dir!(),
          "dragonex-browser-death-save-#{Ecto.UUID.generate()}"
        )

    File.mkdir_p!(artifacts)
    IO.puts("Browser evidence: #{artifacts}")

    http =
      start_supervised!(
        {Bandit, plug: DragonexWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(http)

    {:ok, user} =
      Accounts.register(%{
        email: "browser-death-#{Ecto.UUID.generate()}@dragonex.test",
        password: "browser-password123",
        display_name: "Jugador de prueba"
      })

    hero = %{Archetypes.fighter() | hp: 0}
    companion = Archetypes.fighter(name: "Mara")
    enemy = Character.new(name: "Goblin", side: "enemy", hp: 30, max_hp: 30, ac: 12)

    {:ok, guest} =
      Accounts.register(%{
        email: "browser-companion-#{Ecto.UUID.generate()}@dragonex.test",
        password: "browser-password123",
        display_name: "Segunda jugadora"
      })

    {:ok, game} =
      Games.create_game(
        title: "Recuperación del humano caído",
        scene: "El patio de las ruinas está en silencio.",
        user_id: user.id,
        dice_engine: "2d",
        open_slots: 1,
        roster: [{hero, :human}, {enemy, :ai}]
      )

    {:ok, game} = Games.join_game(game, guest, companion)
    {:ok, before} = World.begin_combat(["Thane", "Mara", "Goblin"]).(Games.load_world(game))
    {:ok, before} = World.set_current_combatant("Thane").(before)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    remaining = start_supervised!({Agent, fn -> [{20, 20}, {10, 5}] end})
    parent = self()

    roller = fn sides ->
      Agent.get_and_update(remaining, fn
        [{^sides, value} | rest] -> {value, rest}
        other -> flunk("Unexpected d#{sides}; remaining #{inspect(other)}")
      end)
    end

    rejected_then_paid = %Test{
      script: [
        narration("Cierro el turno sin resolver la salvación."),
        fn messages, _ ->
          text = messages |> Dragonex.Test.ModelMessages.project() |> inspect(limit: :infinity)
          assert text =~ "SALVACIÓN DE MUERTE PENDIENTE"
          assert text =~ "Registra primero la salvación"
          send(parent, :death_save_guard_corrected)
          death_save()
        end,
        fn _, _ -> raise "scripted failure after paid death save" end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: rejected_then_paid, roller: roller)

    browser =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:line, 262_144},
        args: [Path.join(__DIR__, "death_save_journey.py")]
      ])

    try do
      browser_step(browser, %{
        step: "open",
        url: "http://localhost:#{port}",
        game_id: game.id,
        email: user.email,
        password: "browser-password123",
        artifacts: artifacts
      })

      browser_step(browser, %{step: "declare", text: @declaration})
      assert :ok = Game.await(pid, &(&1.status == :paused), 5_000)
      assert_received :death_save_guard_corrected
      paid = Game.world(pid)
      assert paid.characters["Thane"].hp == 1
      assert paid.characters["Thane"].death_saves == %{successes: 0, fails: 0}
      assert paid.turn_state["Thane"]["death_save"] == true
      refute paid.turn_state["Thane"]["action"]
      assert paid.actor_checkpoint["death_save_required"] == true
      assert Agent.get(remaining, & &1) == [{10, 5}]
      assert count_dice(game.id, "death_save") == 1
      assert player_voice(game.id) == []
      assert Games.load_world(Games.get_game(game.id)) == paid

      browser_step(browser, %{step: "reload_paid"})

      recovered = %Test{
        script: [
          death_save(),
          tool_calls([call("second_wind", %{"who" => "Thane"})]),
          narration("La declaración queda registrada.")
        ]
      }

      {:ok, reopened} = Game.restart(game.id, model: recovered, roller: roller)
      refute reopened == pid
      refute Process.alive?(pid)
      assert Game.world(reopened) == paid

      browser_step(browser, %{step: "recover"})
      assert :ok = Game.await(reopened, &(&1.status == :waiting and &1.current == "Mara"), 5_000)
      healed = Game.world(reopened)
      assert healed.characters["Thane"].hp == 7
      assert healed.characters["Thane"].second_wind_used
      assert healed.turn_state["Thane"]["bonus"]
      assert healed.characters["Mara"] == before.characters["Mara"]
      assert healed.characters["Goblin"] == before.characters["Goblin"]
      assert Agent.get(remaining, & &1) == []
      assert count_dice(game.id, "death_save") == 1
      assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2
      assert [%{payload: %{"text" => @declaration}}] = player_voice(game.id)

      browser_step(browser, %{step: "pause_reload"})
      assert Game.status(reopened) == :paused
      assert Games.load_world(Games.get_game(game.id)) == healed
      events = Games.list_events(game.id)

      {:ok, final} =
        Game.restart(game.id,
          model: %Test{script: [fn _, _ -> flunk("Paused restart must not ask the model") end]},
          roller: fn _ -> flunk("Paused restart must not roll") end
        )

      refute final == reopened
      refute Process.alive?(reopened)
      browser_step(browser, %{step: "final_reload"})
      assert Game.status(final) == :paused
      assert Game.world(final) == healed
      assert Games.list_events(game.id) == events
      browser_step(browser, %{step: "close"})

      File.write!(
        Path.join(artifacts, "engine.json"),
        Jason.encode!(
          %{
            game_id: game.id,
            hit_points: [0, 1, 7],
            guard_corrected: true,
            death_save_rolls: 1,
            total_dice_events: 2,
            human_voice_events: 1,
            second_wind_spent: true,
            game_restarts: 2,
            status: "paused"
          },
          pretty: true
        )
      )
    after
      if Port.info(browser), do: Port.close(browser)
    end
  end

  defp death_save,
    do: tool_calls([call("make_death_save", %{"character" => "Thane"})])

  defp count_dice(id, kind),
    do: Enum.count(Games.list_events(id), &(&1.type == :dice and &1.payload["kind"] == kind))

  defp player_voice(id),
    do: Enum.filter(Games.list_events(id), &(&1.type == :narration and &1.actor == "Thane"))

  defp browser_step(port, command) do
    true = Port.command(port, Jason.encode!(command) <> "\n")

    receive do
      {^port, {:data, {:eol, json}}} ->
        response = Jason.decode!(json)
        assert response["ok"], "Browser #{command.step}: #{inspect(response)}"
        response

      {^port, {:exit_status, status}} ->
        flunk("Browser exited with status #{status} during #{command.step}")
    after
      30_000 -> flunk("Browser timed out during #{command.step}")
    end
  end
end
