defmodule DragonexWeb.GameCreationTextTest do
  use DragonexWeb.ConnCase, async: false
  alias Dragonex.{Accounts, Games, Repo}

  @style String.duplicate(
           "Narra con pocas frases y conserva las decisiones de cada personaje.\n",
           8
         )
  @fields %{
    "custom_title" => "El farol del vado",
    "custom_scene" => "Ada espera en la casa de peaje.",
    "custom_dm_style" => @style
  }

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "creation-text#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "Guardián"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn}
  end

  defp details(view, fields) do
    view |> element("#scenario-custom") |> render_click()

    for field <- Map.keys(fields),
        do:
          view
          |> form("#custom-scenario-form", fields)
          |> render_change(%{"_target" => [field]})
  end

  defp characters(view) do
    view |> element("button[phx-click=pick_hero][phx-value-key=fighter]") |> render_click()
    view |> element("button[phx-click=open_picker][phx-value-slot='0']") |> render_click()

    view
    |> element("button[phx-click=pick_companion][phx-value-slot='0'][phx-value-key=wizard]")
    |> render_click()
  end

  defp dm_style(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#custom_dm_style")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  test "the wizard creates a detailed custom adventure with every submitted word", %{conn: conn} do
    {:ok, view, _} = live(conn, "/games/new")
    details(view, @fields)
    view |> render_click("next")
    characters(view)
    view |> render_click("next")
    {path, _flash} = assert_redirect(view)
    game = Games.get_game(String.to_integer(String.replace_prefix(path, "/games/", "")))
    assert game.title == @fields["custom_title"]
    assert game.dm_style == @style
    assert Games.load_world(game).scene == @fields["custom_scene"]
    assert Enum.find(game.participants, &(&1.name == "Thane")).kind == :human
    assert Enum.find(game.participants, &(&1.name == "Lyra")).kind == :ai
  end

  test "oversized titles keep details and characters recoverable including forged final changes",
       %{
         conn: conn
       } do
    {:ok, view, _} = live(conn, "/games/new")
    count = Repo.aggregate(Dragonex.Games.Game, :count)
    long = String.duplicate("x", 256)
    details(view, Map.put(@fields, "custom_title", long))
    view |> render_click("next")
    assert has_element?(view, "#custom_title[value='#{long}'][aria-invalid=true]")
    assert has_element?(view, "#creation-error[role=alert]", "255")
    assert dm_style(view) == @style
    refute has_element?(view, "[phx-click=pick_hero]")
    assert Repo.aggregate(Dragonex.Games.Game, :count) == count

    view
    |> form("#custom-scenario-form", @fields)
    |> render_change(%{"_target" => ["custom_title"]})

    view |> render_click("next")
    characters(view)
    render_change(view, "change", %{"_target" => ["custom_title"], "custom_title" => long})
    view |> render_click("next")
    assert has_element?(view, "#creation-error[role=alert]", "255")

    assert has_element?(
             view,
             "button[phx-click=pick_hero][phx-value-key=fighter][aria-pressed=true]"
           )

    assert has_element?(view, "button[aria-label='Quitar a Lyra (Mago)']")
    assert Repo.aggregate(Dragonex.Games.Game, :count) == count

    view |> render_click("back")
    assert has_element?(view, "#custom_title[value='#{long}']")
    assert dm_style(view) == @style

    view
    |> form("#custom-scenario-form", @fields)
    |> render_change(%{"_target" => ["custom_title"]})

    view |> render_click("next")
    view |> render_click("next")
    {path, _flash} = assert_redirect(view)
    game = Games.get_game(String.to_integer(String.replace_prefix(path, "/games/", "")))
    assert game.dm_style == @style
    assert Enum.map(game.characters, & &1.name) |> Enum.sort() == ["Lyra", "Thane"]
  end
end
