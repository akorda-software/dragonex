defmodule DragonexWeb.HeroLevelUpLiveTest do
  @moduledoc """
  Flujo UI de la pantalla de subida de nivel (milestone): un héroe por debajo
  del nivel máximo puede subir sin necesidad de XP; a nivel 20 se redirige.
  """

  use DragonexWeb.ConnCase, async: false

  alias Dragonex.{Accounts, Archetypes, Game, Games, Heroes, World}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "lu#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "LU"
      })

    {:ok, char} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, hero} = Accounts.save_hero(user, char)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn, user: user, hero: hero}
  end

  test "un héroe puede subir de nivel desde su ficha (milestone, sin XP)", %{
    conn: conn,
    user: user,
    hero: hero
  } do
    {:ok, view, html} = live(conn, "/heroes/#{hero.id}/level-up")
    assert html =~ "Subir de nivel"

    view |> render_click("confirm")

    assert Accounts.get_user_hero(user, hero.id).level == 2
    assert_redirect(view, "/heroes/#{hero.id}")
  end

  test "a nivel 20, /heroes/:id/level-up redirige a la ficha", %{
    conn: conn,
    user: user,
    hero: hero
  } do
    hero =
      Enum.reduce(1..19, hero, fn _, h ->
        {:ok, h2} = Accounts.level_up_hero(user, h.id, %{})
        h2
      end)

    assert hero.level == 20

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/heroes/#{hero.id}/level-up")
    assert to == "/heroes/#{hero.id}"
  end

  test "confirming a caster level-up syncs new capacity without refunding its live expenditure",
       %{conn: conn, user: user} do
    sheet = Archetypes.wizard()
    {:ok, hero} = Accounts.save_hero(user, sheet)

    {:ok, game} =
      Games.create_game(
        title: "Live progression",
        user_id: user.id,
        roster: [{sheet, :human, hero.id}]
      )

    before = Games.load_world(game)
    {:ok, before} = World.consume_slot(sheet.name, 1).(before)
    {:ok, before} = World.apply_damage(sheet.name, 3).(before)
    {:ok, _} = Games.save_state(game.id, before, sheet.name, before.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %ExAgent.Models.Test{}]}})
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/level-up")
    view |> element("button[phx-click=confirm]") |> render_click()
    assert_redirect(view, "/heroes/#{hero.id}")
    assert Accounts.get_user_hero(user, hero.id).level == 2
    assert Game.world(pid).spell_slots[sheet.name] == %{1 => 2}
    assert Game.world(pid).characters[sheet.name].hp == before.characters[sheet.name].hp
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    assert Game.snapshot(pid).status == :paused
  end

  test "two tabs cannot confirm an old target level twice", %{conn: conn, user: user, hero: hero} do
    {:ok, first, _} = live(conn, "/heroes/#{hero.id}/level-up")
    {:ok, stale, _} = live(conn, "/heroes/#{hero.id}/level-up")
    render_click(first, "confirm")
    assert_redirect(first, "/heroes/#{hero.id}")
    assert Accounts.get_user_hero(user, hero.id).level == 2
    result = render_click(stale, "confirm")
    assert Accounts.get_user_hero(user, hero.id).level == 2

    assert %{
             "info" =>
               "Tu héroe ya ha cambiado. Revisa su ficha antes de volver a subir de nivel."
           } = assert_redirect(stale, "/heroes/#{hero.id}")

    {:ok, shown, _} = follow_redirect(result, conn, "/heroes/#{hero.id}")
    assert has_element?(shown, "#app-flash-info[role=status]", "Tu héroe ya ha cambiado.")
    shown |> element("#app-flash-info button") |> render_click()
    refute has_element?(shown, "#app-flash-info")
  end
end
