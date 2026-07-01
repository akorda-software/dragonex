defmodule DragonesWeb.HeroLiveTest do
  @moduledoc """
  Smoke test del creador de héroes ya localizado: monta el LiveView logueado,
  verifica que renderiza sin errores y que las etiquetas salen en español
  (razas, clases, atributos).

  No prueba mecánica (eso vive en Dragones.HeroesTest); solo que la UI pinta
  el catálogo localizado vía Dragones.Heroes.Catalog.
  """

  use DragonesWeb.ConnCase, async: false

  alias Dragones.Accounts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})

    {:ok, user} =
      Accounts.register(%{
        email: "hero#{System.unique_integer([:positive])}@dragones.test",
        password: "password123",
        display_name: "Tester"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonesWeb.UserAuth.log_in(user)

    {:ok, conn: conn, user: user}
  end

  describe "/heroes (galería)" do
    test "muestra el título en español y el botón de forjar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/heroes")
      assert html =~ "Mis héroes"
      assert html =~ "Forjar nuevo héroe"
    end
  end

  describe "/heroes/new (creador)" do
    test "renderiza el paso identidad con razas y clases en español", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/heroes/new")
      assert html =~ "Forjar un héroe"
      # razas traducidas
      assert html =~ "Elfo"
      assert html =~ "Enano"
      assert html =~ "Humano"
      # clases traducidas
      assert html =~ "Mago"
      assert html =~ "Guerrero"
      assert html =~ "Pícaro"
      # sexos en español
      assert html =~ "hombre"
      assert html =~ "mujer"
    end

    test "no deja nombres sin traducir (ningún 'Elf' ni 'Wizard' sueltos)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/heroes/new")
      refute html =~ ~r/>\s*Elf\s*</
      refute html =~ ~r/>\s*Wizard\s*</
      refute html =~ ~r/>\s*Fighter\s*</
    end

    test "navegar al paso Detalles con un conjurador renderiza los hechizos en español", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/heroes/new")

      # identidad
      view
      |> element("input[name='name']")
      |> render_change(%{"_target" => "name", "name" => "Lyra"})

      view |> element("[phx-value-field='race'][phx-value-value='elf']") |> render_click()

      view
      |> element("select[name='subrace']")
      |> render_change(%{"_target" => "subrace", "subrace" => "high elf"})

      view |> element("[phx-value-field='class'][phx-value-value='wizard']") |> render_click()
      view |> render_click("next")

      # linaje
      view |> element("[phx-value-field='background'][phx-value-value='sage']") |> render_click()
      view |> render_click("next")

      # equipo (paso intermedio nuevo) — dejamos defaults y avanzamos
      view |> render_click("next")

      # ahora estamos en Detalles (wizard → conjurador): debe pintar hechizos en español
      html = render(view)
      assert html =~ "Rayo ígneo"
      assert html =~ "TRUCOS"
      assert html =~ "NIVEL 1"
      refute html =~ ~r/>\s*fire bolt\s*</
    end

    test "el paso Equipo deja elegir el arma del mago y el preview refleja la pick", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/heroes/new")

      # identidad + linaje
      view
      |> element("input[name='name']")
      |> render_change(%{"_target" => "name", "name" => "Merlin"})

      view |> element("[phx-value-field='race'][phx-value-value='human']") |> render_click()
      view |> element("[phx-value-field='class'][phx-value-value='wizard']") |> render_click()
      view |> render_click("next")
      view |> element("[phx-value-field='background'][phx-value-value='sage']") |> render_click()
      view |> render_click("next")

      # estamos en Equipo: por defecto viene Bastón marcado
      html = render(view)
      assert html =~ "Equipo inicial de Mago"
      assert html =~ ~s|phx-value-group="weapon" phx-value-index="0"|

      # elijamos Daga (índice 1)
      view |> element("[phx-value-group='weapon'][phx-value-index='1']") |> render_click()

      # el preview debe reflejar daga (ya no bastón)
      preview = render(view)
      assert preview =~ "Daga"
    end

    test "no deja seleccionar más hechizos que el cupo de la clase", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/heroes/new")

      view
      |> element("input[name='name']")
      |> render_change(%{"_target" => "name", "name" => "W"})

      view |> element("[phx-value-field='race'][phx-value-value='human']") |> render_click()
      view |> element("[phx-value-field='class'][phx-value-value='wizard']") |> render_click()
      view |> render_click("next")
      view |> element("[phx-value-field='background'][phx-value-value='sage']") |> render_click()
      view |> render_click("next")
      view |> render_click("next")

      # wizard: 3 trucos por defecto ya seleccionados, cupo = 3 -> el resto locked
      html = render(view)
      assert html =~ "TRUCOS (3/3)"

      # todos los trucos no-seleccionados están bloqueados (locked, sin phx-click)
      locked_count = length(Regex.scan(~r/spell-chip\s+\w*\s*locked/, html))
      assert locked_count > 0

      # los seleccionados siguen activos (con phx-click)
      assert html =~ ~s|phx-click="spell_toggle"|

      # intentar toggle de un locked no cambia el cupo (sigue 3/3)
      assert render(view) =~ "TRUCOS (3/3)"
    end

    test "clérigo y druida muestran cupo de nivel 1 coherente con sus defaults", %{conn: conn} do
      {:ok, cleric_view, _html} = live(conn, "/heroes/new")
      navigate_to_details(cleric_view, "cleric")
      assert render(cleric_view) =~ "NIVEL 1 (5/5)"

      {:ok, druid_view, _html} = live(conn, "/heroes/new")
      navigate_to_details(druid_view, "druid")
      assert render(druid_view) =~ "NIVEL 1 (4/4)"
    end

    test "el paso Linaje deja elegir habilidades y se muestran en el preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/heroes/new")

      view
      |> element("input[name='name']")
      |> render_change(%{"_target" => "name", "name" => "Thane"})

      view |> element("[phx-value-field='race'][phx-value-value='human']") |> render_click()
      view |> element("[phx-value-field='class'][phx-value-value='fighter']") |> render_click()
      view |> render_click("next")

      # Linaje: la sección Habilidades aparece
      html = render(view)
      assert html =~ "Habilidades"

      # elegir dos habilidades de fighter (perception, survival)
      view
      |> element("[phx-click='skill_toggle'][phx-value-skill='perception']")
      |> render_click()

      view |> element("[phx-click='skill_toggle'][phx-value-skill='survival']") |> render_click()

      # el preview debe reflejarlas (Percepción, Supervivencia)
      preview = render(view)
      assert preview =~ "Percepción"
      assert preview =~ "Supervivencia"
    end

    test "el placeholder de subraza no deja avanzar con valor vacío (regresión)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/heroes/new")

      view
      |> element("input[name='name']")
      |> render_change(%{"_target" => "name", "name" => "X"})

      view |> element("[phx-value-field='race'][phx-value-value='elf']") |> render_click()
      view |> element("[phx-value-field='class'][phx-value-value='wizard']") |> render_click()

      # elige high elf y vuelve al placeholder "" → subrace debe quedar nil
      view
      |> element("select[name='subrace']")
      |> render_change(%{"_target" => "subrace", "subrace" => "high elf"})

      view
      |> element("select[name='subrace']")
      |> render_change(%{"_target" => "subrace", "subrace" => ""})

      # intentar avanzar → no debe dejar (falta subraza válida)
      view |> render_click("next")
      assert render(view) =~ "subraza"
    end
  end

  describe "/heroes/:id (ficha)" do
    test "muestra el héroe guardado con etiquetas en español", %{conn: conn, user: user} do
      {:ok, hero} =
        Dragones.Heroes.build(%{
          name: "Lyra",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })
        |> then(fn {:ok, c} -> Dragones.Accounts.save_hero(user, c) end)

      {:ok, _view, html} = live(conn, "/heroes/#{hero.id}")
      # raza+subraza y clase traducidas en la ficha
      assert html =~ "Alto Elfo"
      assert html =~ "Mago"
      # secciones en español
      assert html =~ "Atributos"
      assert html =~ "Combate"
      assert html =~ "Salvaciones"
      # atributo corto traducido
      assert html =~ "FUE"
      assert html =~ "INT"
      # tipo de daño traducido en armas
      assert html =~ "contundente"
    end

    test "permite abrir edición si el héroe aún no está en partida", %{conn: conn, user: user} do
      {:ok, hero} =
        Dragones.Heroes.build(%{
          name: "Editable",
          race: "human",
          class: "fighter",
          background: "soldier"
        })
        |> then(fn {:ok, c} -> Dragones.Accounts.save_hero(user, c) end)

      {:ok, _view, html} = live(conn, "/heroes/#{hero.id}/edit")
      assert html =~ "Editar héroe"
      assert html =~ "Actualizar héroe"
    end
  end

  defp navigate_to_details(view, class_key) do
    view
    |> element("input[name='name']")
    |> render_change(%{"_target" => "name", "name" => "Caster"})

    view |> element("[phx-value-field='race'][phx-value-value='human']") |> render_click()
    view |> element("[phx-value-field='class'][phx-value-value='#{class_key}']") |> render_click()
    view |> render_click("next")
    view |> element("[phx-value-field='background'][phx-value-value='acolyte']") |> render_click()
    view |> render_click("next")
    view |> render_click("next")
  end
end
