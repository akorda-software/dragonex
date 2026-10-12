defmodule DragonexWeb.GameDiceEngineTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias DragonexWeb.GameLive.Dice

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "dice-engine-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{conn: conn, user: user}
  end

  defp supports_3d? do
    Code.ensure_loaded?(DicEx) and function_exported?(DicEx, :renderer_capabilities, 0) and
      apply(DicEx, :renderer_capabilities, []).authoritative_3d == true
  end

  test "the creator only accepts a 3D preference when the installed package can honor engine faces",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/games/new")
    selector = "button[phx-click=pick_engine][phx-value-engine='3d']"

    if supports_3d?() do
      refute has_element?(view, selector <> "[disabled]")
      view |> element(selector) |> render_click()
      assert has_element?(view, selector <> "[aria-pressed=true]")
    else
      assert has_element?(view, selector <> "[disabled]", "No disponible")
      render_hook(view, "pick_engine", %{"engine" => "3d"})
      assert has_element?(view, "button[phx-value-engine='2d'][aria-pressed=true]")
      assert assigns(view).dice_engine == "2d"
    end
  end

  test "legacy preference, controls and snapshots use the same available mode without writing the game",
       %{conn: conn, user: user} do
    {:ok, game} =
      Games.create_game(
        title: "Preferencia anterior",
        scene: "El cruce.",
        dice_engine: "3d",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    world = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, model: %ExAgent.Models.Test{})
    on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
    events = Games.list_events(game.id)
    {:ok, first, _} = live(conn, "/games/#{game.id}")
    {:ok, second, _} = live(conn, "/games/#{game.id}")
    mode = if supports_3d?(), do: "3d", else: "2d"
    # The same resolved mode must name both the mounted hook and roll event.
    send(first.pid, {:dice_group, game.id, %{who: "Thane", dice: [{20, 16}], total: 19}})
    render(first)
    send(first.pid, {:flush_dice, assigns(first).dice_token})
    render(first)

    target = "dic_ex:roll:dice-stage-#{mode}"

    assert_push_event(first, ^target, %{
      authoritative: true,
      groups: [%{sides: 20, rolls: [%{value: 16}]}]
    })

    render_hook(first, "toggle_dice_engine", %{})
    assert assigns(first).dice_engine == mode
    render_hook(first, "dismiss_dice", %{})

    if supports_3d?() do
      assert has_element?(
               first,
               "button[phx-click=toggle_dice_engine][aria-label='Dados 3D. Cambiar a 2D.']",
               "3D"
             )

      first |> element("button[phx-click=toggle_dice_engine]") |> render_click()
      assert has_element?(first, "#dice-stage-2d[phx-hook=DiceRoller2D]")
      assert has_element?(second, "#dice-stage-3d[phx-hook=DiceRoller]")
    else
      assert assigns(first).dice_engine == "2d"
      refute has_element?(first, "button[phx-click=toggle_dice_engine]")
      assert has_element?(first, "#dice-engine-mode", "2D")
      render_hook(first, "toggle_dice_engine", %{})
      assert assigns(first).dice_engine == "2d"
      assert has_element?(second, "#dice-stage-2d[phx-hook=DiceRoller2D]")
    end

    send(first.pid, {:game_updated, game.id})
    render(first)
    assert assigns(first).dice_engine == "2d"
    assert Game.world(pid) == world
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Games.get_game(game.id).dice_engine == "3d"
    assert Games.list_events(game.id) == events
  end

  test "rendering a stored 3D preference directly uses the available stage identifier and hook" do
    html = render_component(&Dice.stage/1, engine: "3d")
    dom = LazyHTML.from_fragment(html)
    {mode, hook} = if supports_3d?(), do: {"3d", "DiceRoller"}, else: {"2d", "DiceRoller2D"}
    assert Enum.count(LazyHTML.query(dom, "#dice-stage-#{mode}[phx-hook=#{hook}]")) == 1
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
