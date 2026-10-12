defmodule Dragonex.InventoryTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Brief, Codec, Games, Item, World}

  defp world do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: []}

    World.new(scene: "El cruce del molino.", characters: %{hero.name => hero})
    |> World.init_spell_slots()
  end

  test "descriptive loot changes only inventory and survives the existing codec" do
    before = world()
    assert {:ok, after_world} = World.grant_item("Mara", "botón de latón", 1).(before)

    assert [%Item{name: "botón de latón", qty: 1, kind: :gear}] =
             after_world.characters["Mara"].inventory

    assert %{before | scene_refresh_pending: true, characters: after_world.characters} ==
             after_world

    assert %{before.characters["Mara"] | inventory: after_world.characters["Mara"].inventory} ==
             after_world.characters["Mara"]

    assert Codec.decode(Codec.encode(after_world)) == after_world
  end

  test "an object already held is not granted again unless the units are additional (D240)" do
    {:ok, one} = World.grant_item("Mara", "libro de cuentas", 1).(world())

    assert {:error, message} = World.grant_item("Mara", " Libro de Cuentas ", 1).(one)
    assert message =~ "libro de cuentas ×1"
    assert message =~ "confirm_inventory_unchanged"
    assert {:error, _} = World.grant_item("Mara", "libro de cuentas", 1, false).(one)
    assert {:error, _} = World.grant_item("Mara", "libro de cuentas", 1, nil).(one)

    assert {:ok, two} = World.grant_item("Mara", "libro de cuentas", 1, true).(one)
    assert [%Item{qty: 2}] = two.characters["Mara"].inventory

    # Once handed over, a new pickup of the same object is a fresh grant.
    {:ok, none} = World.remove_item("Mara", "libro de cuentas", 1).(one)
    assert {:ok, _} = World.grant_item("Mara", "libro de cuentas", 1).(none)
  end

  test "NFC case and spacing share a stack while arithmetic remains in the engine" do
    {:ok, one} = World.grant_item("Mara", "botón de latón", 1).(world())
    {:ok, three} = World.grant_item("Mara", "  BOTO\u0301N   DE LATO\u0301N ", 2, true).(one)
    assert [%Item{name: "botón de latón", qty: 3}] = three.characters["Mara"].inventory
    assert {:ok, two} = World.remove_item("Mara", " BOTÓN DE LATÓN ", 1).(three)
    assert [%Item{qty: 2}] = two.characters["Mara"].inventory
  end

  test "removal uses real stock, never goes negative and removes an empty entry" do
    {:ok, two} = World.grant_item("Mara", "botón de latón", 2).(world())
    assert {:error, _} = World.remove_item("Mara", "botón de latón", 3).(two)
    assert {:error, _} = World.remove_item("Mara", "otro botón", 1).(two)
    assert {:ok, empty} = World.remove_item("Mara", "botón de latón", 2).(two)
    assert empty.characters["Mara"].inventory == []
    assert {:error, _} = World.remove_item("Mara", "botón de latón", 1).(empty)
  end

  test "invalid names and quantities cannot create a stack or exceed its bound" do
    for name <- [nil, "", " ", String.duplicate("x", 161), <<255>>],
        change <- [&World.grant_item/3, &World.remove_item/3] do
      assert {:error, _} = change.("Mara", name, 1).(world())
    end

    for qty <- [nil, 0, -1, 1.5, "1", 10_000],
        change <- [&World.grant_item/3, &World.remove_item/3] do
      assert {:error, _} = change.("Mara", "botón", qty).(world())
    end

    {:ok, full} = World.grant_item("Mara", "botón", 9999).(world())
    assert {:error, _} = World.grant_item("Mara", "botón", 1).(full)
    assert [%Item{qty: 9999}] = full.characters["Mara"].inventory
  end

  test "only present PCs in exploration accept descriptive loot and entry limits hold" do
    before = world()
    monster = Dragonex.Monsters.goblin()
    before = %{before | characters: Map.put(before.characters, monster.name, monster)}
    absent = %{before | absent_characters: %{"Mara" => "Fuera del molino"}}

    for {w, who} <- [
          {before, "nadie"},
          {before, monster.name},
          {absent, "Mara"},
          {%{before | phase: :combat}, "Mara"}
        ],
        change <- [&World.grant_item/3, &World.remove_item/3] do
      assert {:error, _} = change.(who, "botón", 1).(w)
    end

    items = for i <- 1..80, do: %Item{name: "objeto #{i}", qty: 1, kind: :gear}
    full = put_in(before.characters["Mara"].inventory, items)
    assert {:error, _} = World.grant_item("Mara", "objeto nuevo", 1).(full)
    assert {:ok, more} = World.grant_item("Mara", "objeto 1", 1, true).(full)
    assert length(more.characters["Mara"].inventory) == 80
  end

  test "combat equipment is not reclassified or removed as narrative gear" do
    before =
      put_in(world().characters["Mara"].inventory, [
        %Item{name: "chain mail", qty: 1, kind: :armor}
      ])

    assert {:error, _} = World.grant_item("Mara", "chain mail", 1).(before)
    assert {:error, _} = World.remove_item("Mara", "chain mail", 1).(before)
  end

  test "a change validates current stock and level progression preserves adventure inventory" do
    {:ok, one} = World.grant_item("Mara", "botón", 1).(world())
    remove = World.remove_item("Mara", "botón", 1)
    {:ok, empty} = remove.(one)
    assert {:error, _} = remove.(empty)
    old = one.characters["Mara"]
    next = %{old | level: 2, max_hp: old.max_hp + 4, inventory: []}
    merged = Games.merge_character_level_up(one, "Mara", next)
    assert merged.characters["Mara"].inventory == old.inventory
  end

  test "the world brief exposes current inventory with canonical names and quantities" do
    {:ok, before} = World.grant_item("Mara", "botón de latón", 2).(world())
    brief = Brief.world_brief(before, "Mara")
    assert brief =~ "Inventario: botón de latón ×2"
    {:ok, empty} = World.remove_item("Mara", "botón de latón", 2).(before)
    assert Brief.world_brief(empty, "Mara") =~ "Inventario: vacío"
    refute Brief.world_brief(empty, "Mara") =~ "botón de latón"
  end
end
