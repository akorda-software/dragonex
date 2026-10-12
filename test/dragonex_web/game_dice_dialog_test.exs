defmodule DragonexWeb.GameDiceDialogTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  alias Dragonex.{Accounts, Archetypes, Game, Games}

  test "two views retain their own roll generation across snapshots without changing the game" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "dice-dialog-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Tirada accesible",
        scene: "Un camino tranquilo.",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    world = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, model: %ExAgent.Models.Test{label: "Listo."})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, first, _} = live(conn, "/games/#{game.id}")
    {:ok, second, _} = live(conn, "/games/#{game.id}")
    events = Games.list_events(game.id)
    entry = %{who: "Thane", dice: [{20, 16}], total: 19, against: {:dc, 15}, outcome: :success}

    # Only a presentation fixture: no engine roll or persisted event is fabricated.
    for view <- [first, second] do
      send(view.pid, {:dice_group, game.id, entry})
      render(view)
      send(view.pid, {:flush_dice, assigns(view).dice_token})
      render(view)
    end

    stale = assigns(first).dice_hide_token
    send(first.pid, {:dice_group, game.id, %{entry | dice: [{20, 9}], total: 12}})
    render(first)
    send(first.pid, {:flush_dice, assigns(first).dice_token})
    render(first)
    current = assigns(first).dice_hide_token
    send(first.pid, {:hide_dice, stale})
    send(first.pid, :hide_dice)
    send(first.pid, {:game_updated, game.id})
    render(first)
    assert assigns(first).dice_hide_token == current
    assert has_element?(first, "#dice-dialog[role=dialog][aria-hidden=false] #dice-close")
    render_hook(first, "dic_ex:settled:dice-stage-2d", %{})
    assert has_element?(first, ".dg-against", "vs DC 15")
    assert has_element?(first, ".dg-dice", "= 19")
    first |> element("#dice-close") |> render_click()
    assert has_element?(first, "#dice-dialog[aria-hidden=true]")
    refute has_element?(first, "#dice-close")
    assert has_element?(first, "#dice-stage-2d[phx-hook=DiceRoller2D]")
    assert has_element?(second, "#dice-dialog[aria-hidden=false] #dice-close")

    # A slow renderer keeps the dialog open. Missing acknowledgement reveals
    # the committed result, then gives it a separate window to be read.
    animation_token = assigns(second).dice_hide_token
    send(second.pid, {:hide_dice, animation_token})
    render(second)
    assert assigns(second).dice_rolling
    assert has_element?(second, "#dice-dialog[aria-hidden=false] #dice-close")
    send(second.pid, {:dice_animation_timeout, animation_token})
    render(second)
    refute assigns(second).dice_rolling
    assert has_element?(second, ".dg-dice", "= 19")
    assert has_element?(second, ".dg-against", "vs DC 15")
    send(second.pid, {:hide_dice, animation_token})
    render(second)
    assert has_element?(second, "#dice-dialog[aria-hidden=false] #dice-close")
    send(second.pid, {:hide_dice, assigns(second).dice_hide_token})
    render(second)
    assert has_element?(second, "#dice-dialog[aria-hidden=true]")
    render_hook(second, "toggle_dice_engine", %{})

    if DragonexWeb.GameLive.Dice.three_d_available?() do
      assert has_element?(second, "#dice-stage-3d[phx-hook=DiceRoller]")
    else
      assert has_element?(second, "#dice-stage-2d[phx-hook=DiceRoller2D]")
    end

    assert Game.world(pid) == world
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Games.list_events(game.id) == events
    assert Game.current(pid) == "Thane"
    assert Game.snapshot(pid).status == :paused
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
