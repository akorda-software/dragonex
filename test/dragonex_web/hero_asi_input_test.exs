defmodule DragonexWeb.HeroAsiInputTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "asi-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Una mejora segura"
      })

    {:ok, hero} = Accounts.save_hero(user, %{Archetypes.fighter() | str: 19})
    {:ok, hero} = Accounts.level_up_hero(user, hero.id, %{})
    {:ok, hero} = Accounts.level_up_hero(user, hero.id, %{})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{user: user, hero: hero, conn: conn}
  end

  test "unknown and unrelated existing atom names leave the draft connected and unchanged", %{
    conn: conn,
    user: user,
    hero: hero
  } do
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/level-up")

    for ability <- ["unknown_characteristic", "name", "level", "race", nil, 15] do
      render_click(view, "asi_adjust", %{"ability" => ability, "delta" => "1"})
      assert has_element?(view, ".error[role=alert]", "Elige una característica")
      assert has_element?(view, ".asi-remaining strong", "2")
      assert Process.alive?(view.pid)
    end

    assert Accounts.get_user_hero(user, hero.id).level == 3
    assert Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id)).str == 19
  end

  test "malformed and out-of-contract deltas cannot spend points or disconnect", %{
    conn: conn,
    hero: hero
  } do
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/level-up")

    for delta <- ["plus", "", "1.0", "10", "-10", nil, 1, %{}] do
      render_click(view, "asi_adjust", %{"ability" => "str", "delta" => delta})
      assert has_element?(view, ".error[role=alert]", "Elige una característica")
      assert has_element?(view, ".asi-remaining strong", "2")
      assert Process.alive?(view.pid)
    end
  end

  test "incomplete event payloads keep previously chosen points and the live view", %{
    conn: conn,
    hero: hero
  } do
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/level-up")
    render_click(view, "asi_adjust", %{"ability" => "str", "delta" => "1"})

    for payload <- [%{}, %{"ability" => "dex"}, %{"delta" => "1"}] do
      render_click(view, "asi_adjust", payload)
      assert has_element?(view, ".error[role=alert]")
      assert has_element?(view, ".asi-remaining strong", "1")
      assert has_element?(view, ".asi-row strong", "20")
      assert Process.alive?(view.pid)
    end
  end

  test "a valid adjustment recovers the error and respects score and point caps through confirmation",
       %{conn: conn, user: user, hero: hero} do
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/level-up")
    render_click(view, "asi_adjust", %{"ability" => "str", "delta" => "bad"})
    assert has_element?(view, ".error[role=alert]")
    render_click(view, "asi_adjust", %{"ability" => "str", "delta" => "1"})
    refute has_element?(view, ".error")
    render_click(view, "asi_adjust", %{"ability" => "str", "delta" => "1"})
    assert has_element?(view, ".asi-remaining strong", "1")
    render_click(view, "asi_adjust", %{"ability" => "dex", "delta" => "1"})
    assert has_element?(view, ".asi-remaining strong", "0")
    render_click(view, "asi_adjust", %{"ability" => "wis", "delta" => "1"})
    assert has_element?(view, ".asi-remaining strong", "0")
    render_click(view, "asi_adjust", %{"ability" => "con", "delta" => "-1"})
    assert has_element?(view, ".asi-remaining strong", "0")
    render_click(view, "confirm")
    assert_redirect(view, "/heroes/#{hero.id}")
    sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))
    assert sheet.level == 4
    assert sheet.str == 20
    assert sheet.dex == 13
    assert sheet.wis == 10
    assert sheet.con == 14
  end

  test "a level without ASI rejects a hidden adjustment while normal progression still works", %{
    conn: conn,
    user: user
  } do
    {:ok, hero} = Accounts.save_hero(user, Archetypes.fighter(name: "Una subida sin ASI"))
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/level-up")
    refute has_element?(view, ".asi-row")
    render_click(view, "asi_adjust", %{"ability" => "str", "delta" => "1"})
    assert has_element?(view, ".error[role=alert]", "Esta subida no incluye")
    assert Process.alive?(view.pid)
    render_click(view, "confirm")
    assert_redirect(view, "/heroes/#{hero.id}")
    sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))
    assert sheet.level == 2
    assert sheet.str == 16
  end
end
