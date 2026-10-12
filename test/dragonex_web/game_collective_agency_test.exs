defmodule DragonexWeb.GameCollectiveAgencyTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  @sample File.read!(Path.expand("../fixtures/narration/dm_roble_collective_move.txt", __DIR__))

  test "the collective movement is absent from streaming and from the reloaded narration" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "collective-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "La sala tranquila"
      })

    name = "Sylvi del Roble"

    {:ok, game} =
      Games.create_game(
        title: "El grupo conserva sus decisiones",
        user_id: user.id,
        roster: [
          {Archetypes.fighter(name: name), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, {:narration_ready, self()})

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
    assert_receive {:narration_ready, narration_pid}, 1_000

    try do
      turn_id = :sys.get_state(pid).busy.turn_id
      send(view.pid, {:text_delta, game.id, turn_id, "dm", @sample})
      assert has_element?(view, ".live-streaming", "El arrendajo os espera")
      refute has_element?(view, ".live-streaming", "El grupo cruza el umbral")
      refute has_element?(view, ".live-streaming", "al acercaros")
      assert has_element?(view, ".live-streaming", "colgante de piedra")
    after
      send(narration_pid, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == name and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    assert Game.world(pid) == before
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-dm", "El arrendajo os espera")
    refute has_element?(reloaded, "#log .msg-dm", "El grupo cruza el umbral")
    refute has_element?(reloaded, "#log .msg-dm", "al acercaros")
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
