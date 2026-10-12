defmodule DragonexWeb.MobilePlayerSheetTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  alias Dragonex.{Accounts, Archetypes, Game, Games}

  test "solo exploration exposes the viewer's own details inside the mobile drawer" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "mobile-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Mobile QA"
      })

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)

    {:ok, game} =
      Games.create_game(
        title: "Solo mobile",
        scene: "arena",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    Dragonex.Test.GameFixture.start!(
      {Game, {game.id, [model: %Dragonex.Test.Narrator{text: "Thane, ¿qué quieres observar?"}]}}
    )

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert has_element?(view, ".game-rail-right .mobile-player-sheet", "Thane")
    assert has_element?(view, ".mobile-player-sheet", "HP 12/12")
    assert has_element?(view, "#player-input-text[aria-label='Tu acción']")
    pid = Dragonex.Game.Supervisor.whereis(game.id)
    assert :ok = Dragonex.Game.await_turn(pid, "Thane")
    render(view)
    assert has_element?(view, "#player-input button", "Actuar")
    view |> element("button", "Pausa") |> render_click()
    refute has_element?(view, ".my-turn-banner")
    assert has_element?(view, "#player-input button", "Declarar")
  end
end
