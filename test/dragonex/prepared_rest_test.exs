defmodule Dragonex.PreparedRestTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, World, WorldClock}

  defp wizard(name \\ "A") do
    Character.new(name: name, class: "wizard", hp: 2, max_hp: 8, con: 14)
  end

  defp world(characters),
    do: World.new(characters: Map.new(characters, &{&1.name, &1})) |> World.init_spell_slots()

  defp four(_sides), do: 4
  defp no_roll(_sides), do: flunk("this rest must not roll")

  defp transformed_pair do
    a =
      Character.new(
        name: "A",
        class: "druid",
        level: 3,
        hp: 4,
        max_hp: 24,
        con: 14,
        wild_shape_uses: 2
      )

    b = %{a | name: "B", hp: 3, max_hp: 20, con: 16}

    Enum.reduce(["A", "B"], world([a, b]), fn who, current ->
      assert {:ok, _, transform} = Actions.wild_shape(current, who, "wolf")
      assert {:ok, next} = transform.(current)
      next
    end)
  end

  test "a prepared short rest cannot publish six healed HP after another heal leaves room for two" do
    before = world([wizard()])
    assert {:ok, message, rest} = Actions.short_rest(before, "A", &four/1)
    assert message =~ "recupera 6 pg"
    assert message =~ "ahora 8/8"

    assert {:ok, current} = World.heal("A", 4).(before)
    assert current.characters["A"].hp == 6
    assert {:error, _} = rest.(current)

    assert {:ok, corrected, retry} = Actions.short_rest(current, "A", &four/1)
    assert corrected =~ "recupera 2 pg"
    assert {:ok, next} = retry.(current)
    assert next.characters["A"].hp == 8
    assert next.elapsed_seconds == 3600
    assert next.rest_state["A"]["hit_dice_used"] == 1
  end

  test "a prepared long rest refuses an outdated recovery amount after damage" do
    before = world([wizard()])
    assert {:ok, message, rest} = Actions.long_rest(before, "A")
    assert message =~ "recupera 6 pg (2 → 8"
    assert {:ok, current} = World.apply_damage("A", 1).(before)
    assert {:error, _} = rest.(current)

    assert {:ok, corrected, retry} = Actions.long_rest(current, "A")
    assert corrected =~ "recupera 7 pg (1 → 8"
    assert {:ok, next} = retry.(current)
    assert next.characters["A"].hp == 8
    assert next.elapsed_seconds == 28800
    assert next.rest_state["A"]["last_long_rest_start"] == 0
  end

  test "prepared rests cannot use obsolete maximum HP, Constitution, class or level" do
    before = world([wizard()])
    assert {:ok, _, short} = Actions.short_rest(before, "A", &four/1)
    assert {:ok, _, long} = Actions.long_rest(before, "A")

    for {field, value} <- [max_hp: 10, con: 16, class: "fighter", level: 2],
        rest <- [short, long] do
      current = put_in(before.characters["A"], Map.put(before.characters["A"], field, value))
      assert {:error, _} = rest.(current)
    end
  end

  test "extending a form beyond the rest invalidates the native-body healing already prepared" do
    before = transformed_pair()
    assert before.effect_expiries["A"]["wild_shape"] == 3600
    assert {:ok, message, rest} = Actions.short_rest(before, "A", &four/1)
    assert message =~ "recupera 6 pg"
    assert message =~ "ahora 10/24"

    current = WorldClock.track(before, "A", "wild_shape", 7200)
    assert {:error, _} = rest.(current)
    assert current.elapsed_seconds == 0
    assert current.characters["A"].wild_shape.orig_hp == 4
  end

  test "damage confined to a beast that expires does not invalidate its unchanged native recovery" do
    before = transformed_pair()
    assert {:ok, message, rest} = Actions.short_rest(before, "A", &four/1)
    assert {:ok, current} = World.apply_damage("A", 2).(before)
    assert current.characters["A"].hp == 9

    assert {:ok, next} = rest.(current)
    assert message =~ "ahora 10/24"
    assert next.characters["A"].hp == 10
    assert next.characters["A"].con == 14
    assert next.characters["A"].wild_shape == nil
    assert next.elapsed_seconds == 3600
  end

  test "a shared short rest accepts all expiring forms in either member order" do
    before = transformed_pair()

    for names <- [["A", "B"], ["B", "A"]] do
      assert {:ok, message, rest} = Actions.rest_party(before, names, "short", &four/1)
      assert message =~ "A hace un descanso corto y recupera 6 pg"
      assert message =~ "B hace un descanso corto y recupera 7 pg"
      assert {:ok, next} = rest.(before)
      assert next.elapsed_seconds == 3600

      for who <- names do
        assert next.characters[who].hp == 10
        assert next.characters[who].wild_shape == nil
        assert next.characters[who].wild_shape_uses == 2
        assert next.rest_state[who]["hit_dice_used"] == 1
      end
    end
  end

  test "one changed member rejects the complete party rest until all recovery messages are recalculated" do
    before = world([wizard(), wizard("B")])

    for kind <- ["short", "long"] do
      roller = if kind == "short", do: &four/1, else: &no_roll/1
      assert {:ok, _, rest} = Actions.rest_party(before, ["A", "B"], kind, roller)
      assert {:ok, current} = World.heal("B", 3).(before)
      assert {:error, _} = rest.(current)

      assert {:ok, message, retry} = Actions.rest_party(current, ["A", "B"], kind, roller)
      assert message =~ "A hace un descanso"
      assert message =~ "recupera 6 pg"
      assert message =~ "recupera 3 pg"
      assert {:ok, next} = retry.(current)
      assert next.characters["A"].hp == 8
      assert next.characters["B"].hp == 8
      assert next.elapsed_seconds == if(kind == "short", do: 3600, else: 28800)

      if kind == "short" do
        assert next.rest_state["A"]["hit_dice_used"] == 1
        assert next.rest_state["B"]["hit_dice_used"] == 1
      else
        assert next.rest_state["A"]["last_long_rest_start"] == 0
        assert next.rest_state["B"]["last_long_rest_start"] == 0
      end
    end
  end

  test "inventory, scene and another character's HP may change without invalidating the rest" do
    before = world([wizard(), wizard("B")])
    assert {:ok, _, rest} = Actions.long_rest(before, "A")
    assert {:ok, current} = World.grant_item("A", "moneda de cobre", 1).(before)
    assert {:ok, current} = World.set_scene("Un campamento protegido.").(current)
    assert {:ok, current} = World.apply_damage("B", 1).(current)

    assert {:ok, next} = rest.(current)
    assert next.characters["A"].hp == 8
    assert next.characters["A"].inventory == current.characters["A"].inventory
    assert next.characters["B"] == current.characters["B"]
    assert next.scene == current.scene
  end

  test "resource expenditure with unchanged recovery data is still restored by the rest" do
    fighter = Character.new(name: "A", class: "fighter", hp: 4, max_hp: 12, con: 14)
    before = world([fighter])
    assert {:ok, _, rest} = Actions.short_rest(before, "A", &no_roll/1, nil, 0)
    assert {:ok, current} = World.set_second_wind_used("A", true).(before)

    assert {:ok, next} = rest.(current)
    refute next.characters["A"].second_wind_used
    assert next.characters["A"].hp == 4
    assert next.elapsed_seconds == 3600
  end
end
