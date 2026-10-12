defmodule DragonexWeb.GameCliticAgencyTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  @sample File.read!(Path.expand("../fixtures/narration/dm_iria_clitic_gesture.txt", __DIR__))

  test "the real closing preserves the kitchen in streaming and reload without the human's nod" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "clitic-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Decisiones propias"
      })

    name = "Iria del Alba"

    {:ok, game} =
      Games.create_game(
        title: "El gesto queda en manos de la jugadora",
        user_id: user.id,
        roster: [{Archetypes.fighter(name: name), :human}, {Archetypes.wizard(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, {:clitic_narration_ready, self()})

          receive do
            :finish -> narration(@sample <> " #{name}, ¿qué quieres observar?")
          after
            5_000 -> raise "narration was not released"
          end
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert_receive {:clitic_narration_ready, model_pid}, 1_000

    try do
      turn_id = :sys.get_state(pid).busy.turn_id
      send(view.pid, {:text_delta, game.id, turn_id, "dm", @sample})
      assert has_element?(view, ".live-streaming", "Las tres respuestas se posan")
      assert has_element?(view, ".live-streaming", "El calor de la cocina sigue llegando")
      refute has_element?(view, ".live-streaming", "Iria las recoge")
      refute has_element?(view, ".live-streaming", "asintiendo")
    after
      send(model_pid, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == name and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-dm", "El calor de la cocina sigue llegando")
    refute has_element?(reloaded, "#log .msg-dm", "asintiendo")
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
