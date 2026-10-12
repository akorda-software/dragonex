defmodule DragonexWeb.GameGroupDecisionTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]
  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test
  @sample File.read!(Path.expand("../fixtures/narration/dm_granero_group_decision.txt", __DIR__))

  test "a group decision is absent from the live preview and the reopened chronicle" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "decision-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Decidimos en nuestros turnos"
      })

    name = "Mara de la Bruma"

    {:ok, game} =
      Games.create_game(
        title: "El consejo todavía no es una decisión",
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
          receive do: (:finish -> narration(@sample <> " #{name}, ¿qué quieres observar?"))
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert_receive {:narration_ready, narrator}, 1_000

    try do
      turn_id = :sys.get_state(pid).busy.turn_id
      send(view.pid, {:text_delta, game.id, turn_id, "dm", @sample})
      assert has_element?(view, ".live-streaming", "la posadera sacude un trapo")
      refute has_element?(view, ".live-streaming", "La decisión queda tomada")
    after
      send(narrator, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == name and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    assert Game.world(pid) == before
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-dm", "la posadera sacude un trapo")
    refute has_element?(reloaded, "#log .msg-dm", "La decisión queda tomada")
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
