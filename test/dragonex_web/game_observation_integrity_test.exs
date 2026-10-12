defmodule DragonexWeb.GameObservationIntegrityTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}

  for {actor, file} <- [
        {"Lyra", "pc_lyra_light_hour.txt"},
        {"Mara de la Bruma", "pc_mara_light_jar.txt"},
        {"Nera del Camino", "pc_nera_forest_truth.txt"}
      ] do
    test "the real observation from #{actor} stays complete in preview and after reload" do
      Dragonex.Test.Sandbox.start_shared!()
      actor = unquote(actor)

      raw =
        File.read!(Path.expand("../fixtures/narration/" <> unquote(file), __DIR__))
        |> String.trim()

      {:ok, user} =
        Accounts.register(%{
          email: "observation-#{Ecto.UUID.generate()}@dragonex.test",
          password: "password123",
          display_name: "Observaciones"
        })

      {:ok, game} =
        Games.create_game(
          title: "Una observación completa",
          user_id: user.id,
          roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(name: actor), :ai}]
        )

      before = Games.load_world(game)
      {:ok, _} = Games.save_state(game.id, before, actor, before.round, :paused)
      parent = self()

      model = %Test{
        script: [
          fn _, _ ->
            send(parent, {:observation_ready, self()})

            receive do
              :finish -> narration(raw)
            after
              5_000 -> raise "observation not released"
            end
          end
        ]
      }

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game, {game.id, [model: %Dragonex.Test.Narrator{text: "La sala sigue tranquila."}]}}
        )

      assert :ok == Server.set_model(:sys.get_state(pid).pc_agents[actor], model)
      conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
      {:ok, view, _} = live(conn, "/games/#{game.id}")
      view |> element("button[phx-click=resume]") |> render_click()
      assert_receive {:observation_ready, model_pid}, 1_000

      try do
        turn_id = :sys.get_state(pid).busy.turn_id
        send(view.pid, {:text_delta, game.id, turn_id, actor, raw})
        assert has_element?(view, ".live-streaming", raw)
      after
        send(model_pid, :finish)
      end

      assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
      assert :ok == Game.pause(pid)
      {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
      assert has_element?(reloaded, "#log .msg-pc", raw)
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
    end
  end
end
