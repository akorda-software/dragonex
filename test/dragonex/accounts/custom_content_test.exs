defmodule Dragonex.Accounts.CustomContentTest do
  @moduledoc """
  CRUD y validación de mecánicas del contenido custom por usuario.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Accounts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)

    {:ok, user} =
      Accounts.register(%{email: "custom@test", password: "password123", display_name: "C"})

    %{user: user}
  end

  describe "slugify/1" do
    test "lowercase + colapsa separadores" do
      assert Dragonex.Accounts.CustomContent.slugify("Espada Llameante") == "espada_llameante"
      assert Dragonex.Accounts.CustomContent.slugify("  Rayo  del  Caos!  ") == "rayo_del_caos"
    end
  end

  describe "create_custom_content/2 — armas" do
    test "crea un arma con mecánicas válidas", %{user: user} do
      attrs = %{
        kind: "weapon",
        name_es: "Espada Llameante",
        definition: %{
          "dice" => "2d6",
          "damage_type" => "fire",
          "attack_ability" => "str",
          "finesse" => false,
          "ranged" => false
        },
        notes: "Arde al golpe"
      }

      assert {:ok, cc} = Accounts.create_custom_content(user, attrs)
      assert cc.kind == "weapon"
      assert cc.key == "espada_llameante"
      assert cc.name_es == "Espada Llameante"
      assert cc.definition["dice"] == "2d6"
      assert cc.definition["attack_ability"] == "str"
      assert cc.notes == "Arde al golpe"
    end

    test "rechaza dados no parseables", %{user: user} do
      attrs = %{
        kind: "weapon",
        name_es: "Rota",
        definition: %{
          "dice" => "mucho daño",
          "damage_type" => "fire",
          "attack_ability" => "str"
        }
      }

      assert {:error, reason} = Accounts.create_custom_content(user, attrs)
      assert reason =~ "dice"
    end

    test "rechaza attack_ability inválido", %{user: user} do
      attrs = %{
        kind: "weapon",
        name_es: "Rota",
        definition: %{"dice" => "1d6", "damage_type" => "x", "attack_ability" => "carisma"}
      }

      assert {:error, _} = Accounts.create_custom_content(user, attrs)
    end
  end

  describe "create_custom_content/2 — hechizos" do
    test "crea un hechizo de nivel 3 para varias clases", %{user: user} do
      attrs = %{
        kind: "spell",
        name_es: "Tormenta de cuchillas",
        definition: %{
          "level" => 3,
          "kind" => "save",
          "save_ability" => "dex",
          "dice" => "6d6",
          "damage_type" => "slashing",
          "effect" => "Cuchillas giran en un radio.",
          "classes" => ["wizard", "sorcerer"]
        }
      }

      assert {:ok, cc} = Accounts.create_custom_content(user, attrs)
      assert cc.definition["level"] == 3
      assert cc.definition["classes"] == ["wizard", "sorcerer"]
    end

    test "rechaza level fuera de rango", %{user: user} do
      attrs = %{
        kind: "spell",
        name_es: "Roto",
        definition: %{"level" => 12, "kind" => "save", "classes" => ["wizard"]}
      }

      assert {:error, reason} = Accounts.create_custom_content(user, attrs)
      assert reason =~ "level"
    end

    test "rechaza kind save sin save_ability", %{user: user} do
      attrs = %{
        kind: "spell",
        name_es: "Roto",
        definition: %{"level" => 1, "kind" => "save", "classes" => ["wizard"]}
      }

      assert {:error, reason} = Accounts.create_custom_content(user, attrs)
      assert reason =~ "save_ability"
    end

    test "rechaza classes con claves desconocidas", %{user: user} do
      attrs = %{
        kind: "spell",
        name_es: "Roto",
        definition: %{
          "level" => 1,
          "kind" => "save",
          "save_ability" => "dex",
          "classes" => ["ninja"]
        }
      }

      assert {:error, reason} = Accounts.create_custom_content(user, attrs)
      assert reason =~ "desconocidas"
    end
  end

  describe "create_custom_content/2 — objetos" do
    test "crea un objeto mágico con qty", %{user: user} do
      attrs = %{
        kind: "item",
        name_es: "Piedra solar",
        definition: %{"qty" => 3, "kind" => "magic"},
        notes: "Brilla de noche."
      }

      assert {:ok, cc} = Accounts.create_custom_content(user, attrs)
      assert cc.definition["qty"] == 3
      assert cc.definition["kind"] == "magic"
    end

    test "qty por defecto es 1", %{user: user} do
      attrs = %{
        kind: "item",
        name_es: "Frasco",
        definition: %{"kind" => "consumable"}
      }

      assert {:ok, cc} = Accounts.create_custom_content(user, attrs)
      assert cc.definition["qty"] == 1
    end
  end

  describe "unicidad y propiedad" do
    test "dos contenidos con la misma key+kind chocan", %{user: user} do
      attrs = %{
        kind: "weapon",
        name_es: "Espada Llameante",
        definition: %{
          "dice" => "2d6",
          "damage_type" => "fire",
          "attack_ability" => "str"
        }
      }

      assert {:ok, _} = Accounts.create_custom_content(user, attrs)
      assert {:error, :conflict} = Accounts.create_custom_content(user, attrs)
    end

    test "dos usuarios pueden tener la misma key", %{user: user} do
      {:ok, other} =
        Accounts.register(%{email: "other@test", password: "password123", display_name: "O"})

      attrs = %{
        kind: "weapon",
        name_es: "Espada",
        definition: %{"dice" => "1d8", "damage_type" => "slashing", "attack_ability" => "str"}
      }

      assert {:ok, _} = Accounts.create_custom_content(user, attrs)
      assert {:ok, _} = Accounts.create_custom_content(other, attrs)
    end

    test "get_custom_content solo devuelve lo del usuario", %{user: user} do
      {:ok, other} =
        Accounts.register(%{email: "other@test", password: "password123", display_name: "O"})

      assert {:ok, cc} =
               Accounts.create_custom_content(user, %{
                 kind: "weapon",
                 name_es: "Espada",
                 definition: %{
                   "dice" => "1d8",
                   "damage_type" => "slashing",
                   "attack_ability" => "str"
                 }
               })

      assert Accounts.get_custom_content(user, cc.id) != nil
      assert Accounts.get_custom_content(other, cc.id) == nil
    end

    test "custom_content_by_keys resuelve por (kind, key)", %{user: user} do
      {:ok, _} =
        Accounts.create_custom_content(user, %{
          kind: "weapon",
          name_es: "Espada Llameante",
          definition: %{"dice" => "2d6", "damage_type" => "fire", "attack_ability" => "str"}
        })

      assert cc = Accounts.custom_content_by_keys(user, "weapon", "espada_llameante")
      assert cc.name_es == "Espada Llameante"
    end
  end

  describe "list / update / delete" do
    test "list_custom_content filtra por kind", %{user: user} do
      {:ok, _} =
        Accounts.create_custom_content(user, %{
          kind: "weapon",
          name_es: "Espada",
          definition: %{"dice" => "1d8", "damage_type" => "slashing", "attack_ability" => "str"}
        })

      {:ok, _} =
        Accounts.create_custom_content(user, %{
          kind: "spell",
          name_es: "Bola de fuego loca",
          definition: %{
            "level" => 3,
            "kind" => "save",
            "save_ability" => "dex",
            "classes" => ["wizard"]
          }
        })

      assert length(Accounts.list_custom_content(user)) == 2
      assert length(Accounts.list_custom_content(user, "weapon")) == 1
      assert length(Accounts.list_custom_content(user, "spell")) == 1
    end

    test "update revalida mecánicas y regenera slug", %{user: user} do
      {:ok, cc} =
        Accounts.create_custom_content(user, %{
          kind: "weapon",
          name_es: "Espada",
          definition: %{"dice" => "1d8", "damage_type" => "slashing", "attack_ability" => "str"}
        })

      assert {:ok, updated} =
               Accounts.update_custom_content(user, cc.id, %{
                 name_es: "Espada del Caos",
                 definition: %{
                   "dice" => "2d6",
                   "damage_type" => "force",
                   "attack_ability" => "str"
                 }
               })

      assert updated.name_es == "Espada del Caos"
      assert updated.key == "espada_del_caos"
      assert updated.definition["dice"] == "2d6"
    end

    test "update rechaza mecánica inválida", %{user: user} do
      {:ok, cc} =
        Accounts.create_custom_content(user, %{
          kind: "weapon",
          name_es: "Espada",
          definition: %{"dice" => "1d8", "damage_type" => "slashing", "attack_ability" => "str"}
        })

      assert {:error, _} =
               Accounts.update_custom_content(user, cc.id, %{
                 definition: %{
                   "dice" => "roto",
                   "damage_type" => "slashing",
                   "attack_ability" => "str"
                 }
               })
    end

    test "delete elimina la fila", %{user: user} do
      {:ok, cc} =
        Accounts.create_custom_content(user, %{
          kind: "item",
          name_es: "Frasco",
          definition: %{"kind" => "consumable"}
        })

      assert {:ok, _} = Accounts.delete_custom_content(user, cc.id)
      assert Accounts.get_custom_content(user, cc.id) == nil
    end
  end
end
