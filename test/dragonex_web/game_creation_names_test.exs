defmodule DragonexWeb.GameCreationNamesTest do
  use DragonexWeb.ConnCase, async: false

  alias Dragonex.{Accounts, Games, Heroes}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "roster-names-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Anfitrión"
      })

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{user: user, conn: conn}
  end

  test "a saved hero and an archetype with the same name preserve the wizard for correction",
       ctx do
    hero = hero(ctx.user, "Thane")
    {:ok, view, _} = live(ctx.conn, "/games/new")
    render_click(view, "pick_scenario", %{"key" => "custom"})

    fields = %{
      "custom_title" => "La puerta del norte",
      "custom_scene" => "Una puerta entreabierta.",
      "custom_dm_style" => "Narra con frases breves."
    }

    for {field, value} <- fields,
        do: render_change(view, "change", %{"_target" => [field], field => value})

    render_click(view, "next")
    view |> element("#game-hero-hero_#{hero.id}") |> render_click()
    render_click(view, "open_picker", %{"slot" => "0"})

    view
    |> element("button[phx-click=pick_companion][phx-value-slot='0'][phx-value-key=fighter]")
    |> render_click()

    render_click(view, "next")
    assert has_element?(view, "#creation-error[role=alert]", "Ya hay un personaje llamado Thane")
    assert has_element?(view, "#game-hero-hero_#{hero.id}[aria-pressed=true]")
    assert has_element?(view, "button[phx-click=clear_companion][phx-value-slot='0']")
    assert Games.list_games(ctx.user.id) == []
    assert Accounts.hero_sheet(Accounts.get_user_hero(ctx.user, hero.id)).name == "Thane"

    render_click(view, "back")

    for {field, value} <- fields do
      assert has_element?(view, "input[name=#{field}][value='#{value}']")
    end

    render_click(view, "next")
    render_click(view, "clear_companion", %{"slot" => "0"})
    render_click(view, "open_picker", %{"slot" => "0"})

    view
    |> element("button[phx-click=pick_companion][phx-value-slot='0'][phx-value-key=wizard]")
    |> render_click()

    render_click(view, "next")
    [game] = Games.list_games(ctx.user.id)
    assert_redirect(view, "/games/#{game.id}")
    game = Games.get_game(game.id)
    assert game.title == fields["custom_title"]
    assert game.dm_style == fields["custom_dm_style"]
    assert Games.load_world(game).scene == fields["custom_scene"]
    assert Enum.sort(Enum.map(game.characters, & &1.name)) == ["Lyra", "Thane"]
    assert Enum.find(game.characters, &(&1.name == "Thane")).hero_id == hero.id
  end

  test "a hero named DM shows an actionable error and can be replaced", ctx do
    hero = hero(ctx.user, "DM")
    {:ok, view, _} = live(ctx.conn, "/games/new")
    render_click(view, "next")
    view |> element("#game-hero-hero_#{hero.id}") |> render_click()
    render_click(view, "next")

    assert has_element?(view, "#creation-error[role=alert]", "Ya hay un personaje llamado DM")
    assert has_element?(view, "#game-hero-hero_#{hero.id}[aria-pressed=true]")
    assert Games.list_games(ctx.user.id) == []
    assert Accounts.hero_sheet(Accounts.get_user_hero(ctx.user, hero.id)).name == "DM"

    view |> element("#game-hero-fighter") |> render_click()
    render_click(view, "next")
    [game] = Games.list_games(ctx.user.id)
    assert_redirect(view, "/games/#{game.id}")
    assert Games.load_world(Games.get_game(game.id)).characters |> Map.keys() == ["Thane"]
  end

  defp hero(user, name) do
    {:ok, sheet} =
      Heroes.build(%{name: name, race: "human", class: "fighter", background: "soldier"})

    {:ok, hero} = Accounts.save_hero(user, sheet)
    hero
  end
end
