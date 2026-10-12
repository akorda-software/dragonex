defmodule DragonexWeb.HomeLiveTest do
  use DragonexWeb.ConnCase, async: false
  alias DragonexWeb.HomeDemo

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "a visitor lands on the living chronicle with the wordmark and the way in", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ ~s(<img src="/assets/wordmark.svg" alt="Dragonex")
    assert has_element?(view, ".home-mark img[alt=Dragonex]")
    assert has_element?(view, ".home-log .msg-dm", "correteo nervioso")
    assert has_element?(view, ".home-declare a[href='/register']", "Crear cuenta")
    assert has_element?(view, "#home-dice[phx-hook=DiceRoller2D][data-palette]")
    assert has_element?(view, ".home-roll", "tirada de iniciativa d20:19 +3 = 22")
    refute html =~ "welcome-dragon"
  end

  test "the chronicle advances, rolls reach the dice stage and the demo can be paused", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    step = HomeDemo.opening()
    gen = :sys.get_state(view.pid).socket.assigns.demo_gen

    # Vex's turn opens, then his attack rolls the logged d20 on the home stage.
    send(view.pid, {:demo, gen, step})
    assert has_element?(view, ".home-log .th-actor", "Turno de Vex")
    send(view.pid, {:demo, gen, step + 1})

    assert_push_event(view, "dic_ex:roll:home-dice", %{
      groups: [%{sides: 20, rolls: [%{value: 16}]}]
    })

    assert has_element?(view, ".home-roll", "ataque a rata1 con arco corto d20:16 +5 = 21")
    assert has_element?(view, ".home-readout .hr-total", "21")

    render_hook(view, "dic_ex:landed:home-dice", %{"values" => [16]})

    view |> element(".home-foot button") |> render_click()
    assert has_element?(view, ".home-foot button[aria-pressed=true]", "Reanudar demostración")

    # A timer armed before the pause is stale and cannot advance the chronicle.
    send(view.pid, {:demo, gen, step + 2})
    refute has_element?(view, ".home-roll", "daño perforante a rata1")
  end

  test "the topbar carries the pixel wordmark on every page", %{conn: conn} do
    html = conn |> get("/login") |> html_response(200)
    assert html =~ ~s(class="brand-mark")
  end
end
