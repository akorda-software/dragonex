defmodule Dragonex.Heroes.EquipmentChoiceTest do
  @moduledoc """
  Elección de equipo inicial (SRD): cada clase expone grupos con opciones, y el
  builder aplica la pick del usuario. Sin picks → opción 0 (default histórico),
  así no rompe el comportamiento previo.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Heroes, Heroes.Catalog, Heroes.Classes}

  defp build(class_key, picks) do
    Heroes.build(%{
      name: "X",
      race: "human",
      class: class_key,
      background: "soldier",
      equipment_picks: picks
    })
  end

  defp weapon_names(c), do: Enum.map(c.weapons, & &1.name)
  defp has_item?(c, name), do: Enum.any?(c.inventory, &(&1.name == name))

  # --------------------------------------------------------- defaults estables

  describe "sin picks → opción 0 (backward compatible)" do
    test "fighter sigue dando chain mail + shield (AC 18) y longsword + crossbow" do
      {:ok, c} = build("fighter", %{})
      assert c.ac == 18
      assert weapon_names(c) |> Enum.take(2) == ["longsword", "light crossbow"]
    end

    test "wizard sigue dando quarterstaff" do
      {:ok, c} = build("wizard", %{})
      assert "quarterstaff" in weapon_names(c)
    end

    test "rogue sigue dando rapier (finesse) y leather armor (AC 14)" do
      {:ok, c} = build("rogue", %{})
      assert c.ac == 14
      assert Enum.any?(c.weapons, &(&1.name == "rapier" and &1.finesse))
    end
  end

  # --------------------------------------------------------- picks cambian el equipo

  describe "equipment_picks elige la opción del grupo" do
    test "wizard puede cambiar el arma del grupo :weapon a daga (índice 1)" do
      {:ok, c} = build("wizard", %{weapon: 1})
      names = weapon_names(c)
      refute "quarterstaff" in names
      assert "dagger" in names
    end

    test "wizard puede elegir foco arcano en vez de bolsa de componentes" do
      {:ok, c} = build("wizard", %{focus: 1})
      refute has_item?(c, "component pouch")
      assert has_item?(c, "arcane focus")
    end

    test "fighter puede elegir leather + longbow en vez de chain mail" do
      {:ok, c} = build("fighter", %{armor: 1})
      # leather(11) + dex(+2); sigue con escudo del grupo :weapon (default)
      assert c.ac == 15
      assert "longbow" in weapon_names(c)
    end

    test "fighter puede elegir dos armas marciales en vez de arma+escudo" do
      {:ok, c} = build("fighter", %{weapon: 1})
      names = weapon_names(c)
      # dos armas marciales (longsword + shortsword), sin escudo del grupo :weapon
      assert "longsword" in names and "shortsword" in names
    end

    test "cleric puede elegir chain mail (AC más alto que scale mail default)" do
      {:ok, c_default} = build("cleric", %{})
      {:ok, c_chain} = build("cleric", %{armor: 2})
      assert c_chain.ac > c_default.ac
    end

    test "las picks aceptan keys string (vienen del form de LiveView)" do
      {:ok, c} = build("wizard", %{"weapon" => 1})
      assert "dagger" in weapon_names(c)
    end

    test "índice fuera de rango cae a la opción 0 sin romper" do
      {:ok, c} = build("wizard", %{weapon: 99})
      assert "quarterstaff" in weapon_names(c)
    end
  end

  # --------------------------------------------------------- cada clase tiene grupos

  describe "toda clase expone equipment_groups coherentes" do
    for key <- Classes.keys() do
      @tag key: key
      test "#{key}: cada grupo tiene al menos una opción" do
        {:ok, class} = Classes.get(unquote(key))
        assert class.equipment_groups != []

        for g <- class.equipment_groups do
          assert g.options != []
          for opt <- g.options, do: assert(is_list(opt))
        end
      end
    end
  end

  # --------------------------------------------------------- Catálogo localizado

  describe "Catalog.equipment_for_class/2" do
    test "devuelve los grupos del mago con etiquetas en español y por índice" do
      groups = Catalog.equipment_for_class("wizard", :es)
      weapon = Enum.find(groups, &(&1.id == :weapon))
      assert [%{index: 0, label: "Bastón"}, %{index: 1, label: "Daga"}] = weapon.options

      focus = Enum.find(groups, &(&1.id == :focus))
      assert Enum.any?(focus.options, &(&1.label == "Foco arcano"))
    end

    test "describe_slots formatea un bundle con varios elementos" do
      label =
        Catalog.describe_slots(
          [%{armor: "leather armor"}, %{weapon: "longbow"}, %{ammo: "arrows", qty: 20}],
          :es
        )

      assert label == "Armadura de cuero + Arco largo + 20 Flechas"
    end

    test "clase desconocida devuelve []" do
      assert Catalog.equipment_for_class("nope", :es) == []
    end
  end
end
