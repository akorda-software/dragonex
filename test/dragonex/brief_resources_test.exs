defmodule Dragonex.BriefResourcesTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Brief, Character, Codec, Heroes, World}

  defp hero(class, level \\ 2) do
    {:ok, sheet} =
      Heroes.build(%{name: "Ada", race: "human", class: class, level: level, background: "sage"})

    sheet
  end

  defp world(sheet),
    do: World.new(characters: %{sheet.name => sheet}) |> World.init_spell_slots()

  for {class, field, remaining, capacity, label} <- [
        {"monk", :ki, 0, 2, "Ki"},
        {"sorcerer", :sorcery_points, 1, 2, "Puntos de hechicería"},
        {"paladin", :lay_on_hands_pool, 7, 10, "Imposición de manos"},
        {"paladin", :divine_sense_uses, 0, 4, "Sentido divino"},
        {"bard", :bardic_inspiration_uses, 2, 3, "Inspiración bárdica"},
        {"druid", :wild_shape_uses, 1, 2, "Forma salvaje"}
      ] do
    test "the brief exposes #{label} remaining/capacity from the live sheet" do
      sheet =
        hero(unquote(class)) |> Map.put(:cha, 16) |> Map.put(unquote(field), unquote(remaining))

      w = world(sheet)
      brief = Brief.world_brief(w, sheet.name)
      assert brief =~ "#{unquote(label)}: #{unquote(remaining)}/#{unquote(capacity)}"
      assert w.characters[sheet.name] == sheet
      assert w.elapsed_seconds == 0
      assert w.rest_state == %{}
    end
  end

  test "Font of Magic shows paid slots and exhausted points without rebuilding a full reserve" do
    sheet = hero("sorcerer")
    w = world(sheet)
    {:ok, _, change} = Actions.create_spell_slot(w, sheet.name, 1)
    {:ok, paid} = change.(w)
    brief = Brief.world_brief(paid, "dm")
    assert brief =~ "Casillas: N1:4"
    assert brief =~ "Puntos de hechicería: 0/2"
    refute brief =~ "Puntos de hechicería: 2/2"
    assert paid.characters[sheet.name].sorcery_points == 0
    assert paid.elapsed_seconds == 0
  end

  test "newly unlocked ki is visible while a level-one feature remains absent" do
    sheet = hero("monk", 1)
    w = world(sheet)
    refute Brief.world_brief(w, sheet.name) =~ "Ki:"
    {:ok, unlocked} = World.level_up(sheet.name).(w)
    assert Brief.world_brief(unlocked, sheet.name) =~ "Ki: 2/2"
    {:ok, spent} = World.spend_ki(sheet.name, 1).(unlocked)
    assert Brief.world_brief(spent, sheet.name) =~ "Ki: 1/2"
  end

  test "a transformed druid exposes the spent use and the current beast without changing its sheet" do
    sheet = hero("druid")
    w = world(sheet)
    {:ok, _, change} = Actions.wild_shape(w, sheet.name, "wolf")
    {:ok, changed} = change.(w)
    brief = Brief.world_brief(changed, "dm")
    assert brief =~ "Forma salvaje: 1/2"
    assert brief =~ "Forma actual: wolf (no puede conjurar)"
    assert changed.characters[sheet.name].wild_shape.beast == "wolf"
  end

  test "legacy nil points are conservative and remain nil after reading the brief" do
    sheet = %{hero("sorcerer") | sorcery_points: nil}
    w = world(sheet)
    assert Brief.world_brief(w, sheet.name) =~ "Puntos de hechicería: 0/2"
    assert w.characters[sheet.name].sorcery_points == nil
  end

  test "an absent creature's class reserve is not presented as a resource in the scene" do
    sheet = %{hero("sorcerer") | side: "enemy"}
    {:ok, departed} = World.leave_scene(sheet.name, "Se retira.").(world(sheet))
    brief = Brief.world_brief(departed, "dm")
    assert brief =~ "Fuera de escena"
    refute brief =~ "Puntos de hechicería"
  end

  test "single-use recoveries use the actual flags and respect their modeled unlock level" do
    fighter = %{hero("fighter", 1) | second_wind_used: true}
    brief = Brief.world_brief(world(fighter), fighter.name)
    assert brief =~ "Segundo aliento: gastado"
    refute brief =~ "Oleada de acción:"

    fighter = %{fighter | level: 2, action_surge_used: true}
    assert Brief.world_brief(world(fighter), fighter.name) =~ "Oleada de acción: gastado"

    assert Brief.world_brief(world(%{fighter | action_surge_used: false}), fighter.name) =~
             "Oleada de acción: disponible"

    wizard = %{hero("wizard") | arcane_recovery_used: true}
    assert Brief.world_brief(world(wizard), wizard.name) =~ "Recuperación arcana: gastado"
    cleric = %{hero("cleric") | channel_divinity_used: true}
    assert Brief.world_brief(world(cleric), cleric.name) =~ "Canalizar divinidad: gastado"
    refute Brief.world_brief(world(%{cleric | level: 1}), cleric.name) =~ "Canalizar divinidad:"
  end

  test "finite hit dice survive a real rest and Codec instead of following current HP" do
    sheet = %{hero("fighter") | hp: 1}
    w = world(sheet)
    {:ok, _, rest} = Actions.short_rest(w, sheet.name, fn _ -> 1 end, nil, 1)
    {:ok, rested} = rest.(w)
    persisted = rested |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert Brief.world_brief(persisted, sheet.name) =~ "Dados de golpe: 1/2 d10"
    assert persisted.rest_state[sheet.name]["hit_dice_used"] == 1
    assert persisted.elapsed_seconds == 3600
    assert Brief.world_brief(persisted, sheet.name) =~ "Segundo aliento: disponible"
  end

  test "a bare NPC does not acquire PC hit dice or unrelated class resources" do
    npc = %Character{name: "Aldeana", side: "npc"}
    brief = Brief.world_brief(World.new(characters: %{npc.name => npc}), "dm")
    assert brief =~ "Aldeana"
    refute brief =~ "Dados de golpe:"
    refute brief =~ "Puntos de hechicería:"
    refute brief =~ "Segundo aliento:"
  end
end
