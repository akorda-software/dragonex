defmodule DragonexWeb.GameExplicitQuestionTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}

  test "submitting a named question shows the companion's own response and returns the human composer" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "explicit-question-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "La jarra de agua"
      })

    {:ok, game} =
      Games.create_game(
        title: "Vex tiene su propia voz",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}, {Archetypes.rogue(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [
                narration("—Vex, ¿puedes pedir agua a la posadera?"),
                narration("La posadera llena la jarra.")
              ]
            }
          ]}}
      )

    parent = self()
    answer = "—Yo pediría agua fresca para mi jarra."

    response = %Test{
      script: [
        fn _, _ ->
          send(parent, {:explicit_response_ready, self()})

          receive do
            :finish -> narration(answer)
          after
            5_000 -> raise "explicit response was not released"
          end
        end
      ]
    }

    assert :ok == Server.set_model(:sys.get_state(pid).pc_agents["Vex"], response)
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))

    view
    |> element("#player-input")
    |> render_submit(%{"text" => "Vex, ¿puedes pedir agua a la posadera?"})

    assert_receive {:explicit_response_ready, model_pid}, 2_000

    try do
      assert Game.current(pid) == "Vex"
      assert Game.world(pid).conversation["pending"] == ["Vex"]
      turn_id = :sys.get_state(pid).busy.turn_id
      send(view.pid, {:text_delta, game.id, turn_id, "Vex", answer})
      assert has_element?(view, ".live-streaming", answer)
    after
      send(model_pid, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert has_element?(view, ".my-turn-banner")
    assert has_element?(view, "#log .msg-pc", answer)
    view |> element("button[phx-click=pause]") |> render_click()
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-pc", answer)
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
