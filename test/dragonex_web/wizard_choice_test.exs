defmodule DragonexWeb.WizardChoiceTest do
  use DragonexWeb.ConnCase, async: false

  alias Dragonex.Accounts

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "wizard-choice#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "Teclado"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn}
  end

  test "identity choices are native controls and retain their selected state on return", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/heroes/new")
    assert has_element?(view, "label[for=hero-name]", "Nombre")

    for {field, value} <- [{"sex", "mujer"}, {"race", "human"}, {"class", "wizard"}] do
      selector = choice(field, value)
      assert has_element?(view, "button[type=button]#{selector}[aria-pressed=false]")
      view |> element(selector) |> render_click()
      assert has_element?(view, "button#{selector}[aria-pressed=true]")
    end

    name_hero(view)
    view |> render_click("next")
    view |> render_click("back")

    for {field, value} <- [{"sex", "mujer"}, {"race", "human"}, {"class", "wizard"}] do
      assert has_element?(view, "button#{choice(field, value)}[aria-pressed=true]")
    end
  end

  test "heritage exposes selected skills, languages and named point-buy controls", %{conn: conn} do
    {:ok, view, _} = live(conn, "/heroes/new")
    to_heritage(view)

    view |> element(choice("background", "sage")) |> render_click()
    assert has_element?(view, "button#{choice("background", "sage")}[aria-pressed=true]")

    view |> element(choice("score_method", "pointbuy")) |> render_click()
    assert has_element?(view, "button#{choice("score_method", "pointbuy")}[aria-pressed=true]")
    assert has_element?(view, "button[aria-label='Aumentar Fuerza'][phx-value-delta='1']")
    assert has_element?(view, "button[aria-label='Disminuir Fuerza'][phx-value-delta='-1']")

    for selector <- ["[phx-value-skill=arcana]", "[phx-value-lang=elvish]"] do
      assert has_element?(view, "button#{selector}[aria-pressed=false]")
      view |> element(selector) |> render_click()
      assert has_element?(view, "button#{selector}[aria-pressed=true]")
      view |> element(selector) |> render_click()
      assert has_element?(view, "button#{selector}[aria-pressed=false]")
    end
  end

  test "equipment and spell selections remain visible when moving between steps", %{conn: conn} do
    {:ok, view, _} = live(conn, "/heroes/new")
    to_heritage(view)
    view |> element(choice("background", "sage")) |> render_click()
    view |> render_click("next")

    dagger = "button[type=button][phx-value-group=weapon][phx-value-index='1']"
    assert has_element?(view, "#{dagger}[aria-pressed=false]")
    view |> element(dagger) |> render_click()
    assert has_element?(view, "#{dagger}[aria-pressed=true]")
    view |> render_click("next")

    fire_bolt = "button[phx-value-spell='fire bolt']"
    assert has_element?(view, "#{fire_bolt}[aria-pressed=true]")
    view |> element(fire_bolt) |> render_click()
    assert has_element?(view, "#{fire_bolt}[aria-pressed=false]")
    assert has_element?(view, "label[for=hero-backstory]", "Historia")

    view |> render_click("back")
    assert has_element?(view, "#{dagger}[aria-pressed=true]")
    view |> render_click("next")
    assert has_element?(view, "#{fire_bolt}[aria-pressed=false]")
  end

  test "scenario and hero choices expose selection and disable occupied companions", %{conn: conn} do
    {:ok, view, _} = live(conn, "/games/new")
    arena = "button[type=button][phx-value-key=arena]"
    assert has_element?(view, "#{arena}[aria-pressed=false]")
    view |> element(arena) |> render_click()
    assert has_element?(view, "#{arena}[aria-pressed=true]")

    engine = if DragonexWeb.GameLive.Dice.three_d_available?(), do: "3d", else: "2d"

    if engine == "3d" do
      view |> element("button[phx-value-engine='3d']") |> render_click()
    else
      assert has_element?(view, "button[phx-value-engine='3d'][disabled]")
    end

    assert has_element?(view, "button[phx-value-engine='#{engine}'][aria-pressed=true]")
    view |> render_click("next")

    assert has_element?(
             view,
             "button[phx-click=pick_hero][phx-value-key=fighter][aria-pressed=true]"
           )

    assert has_element?(view, "button[phx-click=pick_hero][phx-value-key=wizard][disabled]")
    assert has_element?(view, "button[phx-click=pick_hero][phx-value-key=rogue][disabled]")

    view |> element("button[phx-click=clear_companion][phx-value-slot='0']") |> render_click()
    refute has_element?(view, "button[phx-click=pick_hero][phx-value-key=wizard][disabled]")
    view |> element("button[phx-click=pick_hero][phx-value-key=wizard]") |> render_click()

    assert has_element?(
             view,
             "button[phx-click=pick_hero][phx-value-key=wizard][aria-pressed=true]"
           )

    view |> render_click("back")
    assert has_element?(view, "#{arena}[aria-pressed=true]")
    assert has_element?(view, "button[phx-value-engine='#{engine}'][aria-pressed=true]")
  end

  test "custom adventure text remains visible after going back or changing scenario", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/games/new")
    view |> element("[phx-value-key=custom]") |> render_click()

    fields = %{
      "custom_title" => "Puente de la bruma",
      "custom_scene" => "Un puente sobre el río",
      "custom_dm_style" => "Cálido y breve"
    }

    for {field, value} <- fields do
      view
      |> form("#custom-scenario-form", fields)
      |> render_change(%{"_target" => [field]})

      assert has_element?(view, "label[for=#{field}]")
      assert has_element?(view, "input[name=#{field}][value='#{value}']")
    end

    view |> render_click("next")
    view |> render_click("back")
    view |> element("[phx-value-key=arena]") |> render_click()
    view |> element("[phx-value-key=custom]") |> render_click()

    for {field, value} <- fields do
      assert has_element?(view, "input[name=#{field}][value='#{value}']")
    end
  end

  test "native buttons keep the selected value when browser metadata overrides phx-value", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/heroes/new")
    name_hero(view)

    for {field, value} <- [{"sex", "mujer"}, {"race", "human"}, {"class", "wizard"}] do
      native_choose(view, field, value)
    end

    view |> render_click("next")
    native_choose(view, "background", "sage")
    native_choose(view, "score_method", "pointbuy")
    native_choose(view, "score_method", "auto")
  end

  defp native_choose(view, field, value) do
    selector = "button#{choice(field, value)}"

    # The LiveView JS client reads HTMLButtonElement.value after phx-value-*
    # and overwrites its "value" key. LiveViewTest otherwise skips this step.
    native_value =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("value")
      |> List.first()

    view |> element(selector) |> render_click(%{"value" => native_value || ""})
    assert has_element?(view, "#{selector}[aria-pressed=true]")
  end

  defp choice(field, value), do: "[phx-value-field='#{field}'][phx-value-value='#{value}']"

  defp name_hero(view) do
    view
    |> element("input[name=name]")
    |> render_change(%{"_target" => "name", "name" => "Maga del teclado"})
  end

  defp to_heritage(view) do
    name_hero(view)
    view |> element(choice("race", "human")) |> render_click()
    view |> element(choice("class", "wizard")) |> render_click()
    view |> render_click("next")
  end
end
