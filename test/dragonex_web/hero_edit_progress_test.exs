defmodule DragonexWeb.HeroEditProgressTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Heroes}
  alias Dragonex.Heroes.Draft

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "hero-edit-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Editor"
      })

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{user: user, conn: conn}
  end

  for legacy <- [false, true] do
    test "editing a #{if legacy, do: "legacy", else: "draft-backed"} biography preserves progression after reload",
         ctx do
      {hero, original} = hero(ctx.user, "wizard", 5, legacy: unquote(legacy))
      {:ok, view, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
      change_text(view, "backstory", "Una historia revisada.")
      render_click(view, "save")
      assert_redirect(view, "/heroes")

      saved = Accounts.get_user_hero(ctx.user, hero.id)
      assert Accounts.hero_sheet(saved) == %{original | backstory: "Una historia revisada."}
      {:ok, reopened, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
      assert :sys.get_state(reopened.pid).socket.assigns.preview.level == 5
      change_text(reopened, "name", "Nombre revisado")
      render_click(reopened, "save")
      assert_redirect(reopened, "/heroes")

      assert Accounts.hero_sheet(Accounts.get_user_hero(ctx.user, hero.id)) ==
               %{original | backstory: "Una historia revisada.", name: "Nombre revisado"}
    end
  end

  test "equipment edits save level and ASI once and preserve spent abilities", ctx do
    {hero, original} = hero(ctx.user, "fighter", 5)
    {:ok, view, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
    render_click(view, "equip", %{"group" => "armor", "index" => "1"})
    edited = :sys.get_state(view.pid).socket.assigns.preview
    assert edited.con == original.con
    assert edited.max_hp == original.max_hp
    assert edited.hp == original.hp
    assert edited.ac != original.ac
    render_click(view, "goto", %{"step" => "details"})
    render_click(view, "goto", %{"step" => "review"})
    assert :sys.get_state(view.pid).socket.assigns.preview == edited
    render_click(view, "save")
    assert_redirect(view, "/heroes")
    assert Accounts.hero_sheet(Accounts.get_user_hero(ctx.user, hero.id)) == edited
  end

  test "two saved class changes do not refill the original monk pool", ctx do
    {hero, original} = hero(ctx.user, "monk", 5)
    assert original.ki == 1
    {:ok, first, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
    render_click(first, "select", %{"field" => "class", "value" => "fighter"})
    render_click(first, "save")
    assert_redirect(first, "/heroes")
    assert Accounts.get_user_hero(ctx.user, hero.id).class == "fighter"

    {:ok, second, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
    render_click(second, "select", %{"field" => "class", "value" => "monk"})
    render_click(second, "save")
    assert_redirect(second, "/heroes")
    returned = Accounts.hero_sheet(Accounts.get_user_hero(ctx.user, hero.id))
    assert returned.level == 5
    assert returned.xp == original.xp
    assert returned.ki == 1
    assert returned.hp <= original.hp
  end

  for newer <- [:xp, :level, :edit] do
    test "a stale editor cannot overwrite a newer #{newer} change and keeps its draft", ctx do
      {hero, original} = hero(ctx.user, "fighter", 2)
      {:ok, view, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
      change_text(view, "backstory", "Mi borrador pendiente.")

      result =
        case unquote(newer) do
          :xp ->
            Accounts.grant_xp(ctx.user, hero.id, 500)

          :level ->
            Accounts.level_up_hero(ctx.user, hero.id, %{expected_level: 2})

          :edit ->
            Accounts.update_hero(
              ctx.user,
              hero.id,
              %{original | name: "Otra edición"},
              hero.draft,
              expected: hero
            )
        end

      assert {:ok, concurrent} = result

      render_click(view, "save")
      assert render(view) =~ "Tu héroe ha cambiado"
      assert Accounts.get_user_hero(ctx.user, hero.id).sheet == concurrent.sheet
      state = :sys.get_state(view.pid).socket.assigns
      assert state.form.backstory == "Mi borrador pendiente."
      assert state.preview.backstory == "Mi borrador pendiente."
      assert Process.alive?(view.pid)
    end
  end

  test "stale editor feedback is translated in English", ctx do
    {hero, _original} = hero(ctx.user, "fighter", 2)
    conn = Plug.Conn.put_session(ctx.conn, "locale", "en")
    {:ok, view, _} = live(conn, "/heroes/#{hero.id}/edit")
    {:ok, _} = Accounts.grant_xp(ctx.user, hero.id, 1)
    render_click(view, "save")
    assert render(view) =~ "Your hero has changed"
  end

  test "an invalid preview keeps its actionable error and leaves the stored sheet alone", ctx do
    {hero, original} = hero(ctx.user, "wizard", 2)
    {:ok, view, _} = live(ctx.conn, "/heroes/#{hero.id}/edit")
    change_text(view, "name", "")
    assert render(view) =~ "Ponle nombre a tu héroe"
    render_click(view, "save")
    assert render(view) =~ "Ponle nombre a tu héroe"
    assert Accounts.hero_sheet(Accounts.get_user_hero(ctx.user, hero.id)) == original
    assert :sys.get_state(view.pid).socket.assigns.form.name == nil
  end

  defp change_text(view, field, value),
    do: render_change(view, "change", %{"_target" => [field], field => value})

  defp hero(user, class, level, opts \\ []) do
    form = %{
      Draft.initial_form()
      | name: "Hero",
        race: "human",
        class: class,
        background: "soldier"
    }

    {:ok, original} =
      Heroes.build(%{name: form.name, race: form.race, class: class, background: form.background})

    original =
      Enum.reduce(2..level, original, fn next, sheet ->
        choices = if next == 4, do: %{asi: %{con: 2}}, else: %{}
        {:ok, updated} = Heroes.apply_level_up(sheet, choices)
        updated
      end)

    original = %{
      original
      | hp: 4,
        xp: original.xp + 123,
        second_wind_used: true,
        action_surge_used: true,
        ki: if(class == "monk", do: 1, else: original.ki)
    }

    draft = if Keyword.get(opts, :legacy, false), do: nil, else: Draft.draft_from_form(form)
    {:ok, hero} = Accounts.save_hero(user, original, draft)
    {hero, original}
  end
end
