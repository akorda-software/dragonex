defmodule Dragones.Heroes.CustomContentBuilderTest do
  @moduledoc """
  Integración del contenido custom en el builder: armas/objetos vía
  `extra_equipment`, hechizos vía `spells`, y round-trip por Codec.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Codec, Heroes}

  @bundle %{
    weapons: [
      %{
        key: "custom_espada_llameante",
        name: "Espada Llameante",
        definition: %{
          "dice" => "2d6",
          "damage_type" => "fire",
          "attack_ability" => "str",
          "finesse" => false,
          "ranged" => false
        }
      }
    ],
    spells: [
      %{
        key: "custom_tormenta",
        name: "Tormenta de cuchillas",
        definition: %{
          "level" => 3,
          "kind" => "save",
          "save_ability" => "dex",
          "dice" => "6d6",
          "damage_type" => "slashing",
          "effect" => "Cuchillas giran.",
          "classes" => ["wizard", "sorcerer"]
        }
      },
      %{
        key: "custom_truco_fuego",
        name: "Chispa",
        definition: %{
          "level" => 0,
          "kind" => "attack",
          "save_ability" => nil,
          "dice" => "1d8",
          "damage_type" => "fire",
          "effect" => "Una chispa.",
          "classes" => ["wizard"]
        }
      }
    ],
    items: [
      %{key: "custom_piedra", name: "Piedra solar", definition: %{"qty" => 1, "kind" => "magic"}}
    ]
  }

  defp base(class_key), do: %{name: "X", race: "human", class: class_key, background: "sage"}

  describe "extra_equipment — armas y objetos custom" do
    test "un arma custom se equipa con sus mecánicas y name legible" do
      {:ok, c} =
        Heroes.build(
          Map.merge(base("fighter"), %{
            custom: @bundle,
            extra_equipment: %{weapons: ["custom_espada_llameante"]}
          })
        )

      espada = Enum.find(c.weapons, &(&1.name == "Espada Llameante"))
      assert espada != nil
      assert espada.dice == "2d6"
      assert espada.damage_type == "fire"
      assert espada.attack_ability == :str
    end

    test "un objeto custom se añade al inventario con su qty y kind" do
      {:ok, c} =
        Heroes.build(
          Map.merge(base("fighter"), %{
            custom: @bundle,
            extra_equipment: %{items: [%{key: "custom_piedra", qty: 3}]}
          })
        )

      piedra = Enum.find(c.inventory, &(&1.name == "Piedra solar"))
      assert piedra.qty == 3
      assert piedra.kind == :magic
    end

    test "armas builtin también se pueden añadir como extra sin duplicar lógica" do
      {:ok, c} =
        Heroes.build(Map.merge(base("fighter"), %{extra_equipment: %{weapons: ["javelin"]}}))

      assert Enum.any?(c.weapons, &(&1.name == "javelin"))
    end
  end

  describe "spells — hechizos custom" do
    test "un truco custom se resuelve desde el bundle" do
      {:ok, c} =
        Heroes.build(
          Map.merge(base("wizard"), %{custom: @bundle, spells: ["custom_truco_fuego"]})
        )

      chispa = Enum.find(c.spells, &(&1.name == "Chispa"))
      assert chispa.level == 0
      assert chispa.kind == :attack
      assert chispa.casting_ability == :int
    end

    test "un hechizo custom de nivel superior (3) se conserva tal cual" do
      {:ok, c} =
        Heroes.build(Map.merge(base("wizard"), %{custom: @bundle, spells: ["custom_tormenta"]}))

      tormenta = Enum.find(c.spells, &(&1.name == "Tormenta de cuchillas"))
      assert tormenta.level == 3
      assert tormenta.save_ability == :dex
      assert tormenta.dice == "6d6"
    end
  end

  describe "backward compatibility" do
    test "sin custom ni extra_equipment el builder sigue igual" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lyra",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      assert c.level == 1
      assert Enum.any?(c.spells, &(&1.level == 0))
    end
  end

  describe "Codec round-trip con contenido custom" do
    test "el Character con custom sobrevive encode → decode" do
      {:ok, c} =
        Heroes.build(
          Map.merge(base("wizard"), %{
            custom: @bundle,
            extra_equipment: %{
              weapons: ["custom_espada_llameante"],
              items: [%{key: "custom_piedra", qty: 2}]
            },
            spells: ["custom_truco_fuego"]
          })
        )

      decoded = Codec.decode_character(Codec.encode_character(c))

      espada = Enum.find(decoded.weapons, &(&1.name == "Espada Llameante"))
      assert espada.dice == "2d6"
      assert espada.attack_ability == :str

      assert Enum.any?(decoded.spells, &(&1.name == "Chispa" and &1.level == 0))

      piedra = Enum.find(decoded.inventory, &(&1.name == "Piedra solar"))
      assert piedra.qty == 2
      assert piedra.kind == :magic
    end
  end
end
