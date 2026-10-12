defmodule DragonexWeb.CustomContentLiveTest do
  @moduledoc """
  Flujo UI de la biblioteca de contenido custom: crear y editar (este último
  cazaba el bug de que editar siempre creaba una fila nueva).
  """

  use DragonexWeb.ConnCase, async: false

  alias Dragonex.Accounts

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "cc#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "CC"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn, user: user}
  end

  test "crea un arma custom desde la UI y aparece en la lista", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, "/mi-contenido")
    assert html =~ "Armas"

    # Abrir el form de creación
    view |> render_click("new") =~ "Nombre"

    # Rellenar campos (el handler change lee _target + el valor)
    render_change(view, "change", %{"_target" => ["name"], "name" => "Espada Llameante"})
    render_change(view, "change", %{"_target" => ["dice"], "dice" => "2d6"})
    render_change(view, "change", %{"_target" => ["damage_type"], "damage_type" => "fire"})

    # Guardar
    view |> render_click("save")

    assert [created] = Accounts.list_custom_content(user, "weapon")
    assert created.name_es == "Espada Llameante"
    assert created.definition["dice"] == "2d6"
  end

  test "un arma con checkbox (finesse) y todos los campos se guarda entera", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, "/mi-contenido")
    view |> render_click("new") =~ "Nombre"

    # Cambio del form con todos los campos a la vez (como serializa el browser),
    # incluyendo el checkbox finesse marcado (presente en el payload).
    render_change(view, "change", %{
      "name" => "Daga Veloz",
      "dice" => "1d4",
      "damage_type" => "piercing",
      "attack_ability" => "dex",
      "finesse" => "on"
    })

    view |> render_click("save")

    [created] = Accounts.list_custom_content(user, "weapon")
    assert created.name_es == "Daga Veloz"
    assert created.definition["attack_ability"] == "dex"
    assert created.definition["finesse"] == true
    assert created.definition["ranged"] == false
  end

  test "EDITAR contenido actualiza la fila en vez de crear una nueva", %{conn: conn, user: user} do
    {:ok, cc} =
      Accounts.create_custom_content(user, %{
        kind: "weapon",
        name_es: "Espada",
        definition: %{
          "dice" => "1d8",
          "damage_type" => "slashing",
          "attack_ability" => "str",
          "finesse" => false,
          "ranged" => false
        }
      })

    {:ok, view, _html} = live(conn, "/mi-contenido")

    # Pulsar "editar" sobre la fila existente
    view |> render_click("edit", %{"id" => cc.id})

    # Cambiar el nombre
    render_change(view, "change", %{"_target" => ["name"], "name" => "Espada del Caos"})

    # Guardar cambios
    view |> render_click("save")

    # La fila original se actualizó (mismo id, nuevo nombre) y NO se creó un duplicado.
    reloaded = Accounts.get_custom_content(user, cc.id)
    assert reloaded.name_es == "Espada del Caos"
    assert reloaded.key == "espada_del_caos"
    assert Accounts.list_custom_content(user, "weapon") == [reloaded]
  end
end
