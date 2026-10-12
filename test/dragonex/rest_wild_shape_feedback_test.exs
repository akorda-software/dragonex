defmodule Dragonex.RestWildShapeFeedbackTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, Codec, World}

  defp transformed(level \\ 3, hp \\ 6, max_hp \\ 29) do
    c =
      Character.new(
        name: "Sylvi",
        class: "druid",
        side: "pc",
        level: level,
        hp: hp,
        max_hp: max_hp,
        ac: 14,
        con: 14,
        wis: 16,
        wild_shape_uses: 2
      )

    world = World.new(characters: %{"Sylvi" => c}) |> World.init_spell_slots()
    {:ok, _, change} = Actions.wild_shape(world, "Sylvi", "wolf")
    {:ok, world} = change.(world)
    world
  end

  test "an expiring healthy beast reports the original body's complete recovery" do
    world = transformed()
    assert world.characters["Sylvi"].hp == 11
    {:ok, message, change} = Actions.long_rest(world, "Sylvi")
    assert message =~ "recupera 23 pg (6 → 29"
    refute message =~ "recupera 0 pg"
    {:ok, after_rest} = change.(world)
    assert after_rest.characters["Sylvi"].hp == 29
    assert after_rest.characters["Sylvi"].max_hp == 29
    assert after_rest.characters["Sylvi"].wild_shape == nil
    assert after_rest.characters["Sylvi"].wild_shape_uses == 2
    assert after_rest.elapsed_seconds == 28800
    assert after_rest.rest_state["Sylvi"]["last_long_rest_start"] == 0
    assert world.characters["Sylvi"].wild_shape.orig_hp == 6
    assert world.elapsed_seconds == 0
  end

  test "damage to the beast does not replace the native HP in long-rest feedback after Codec" do
    {:ok, world} = World.apply_damage("Sylvi", 3).(transformed())
    world = world |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert world.characters["Sylvi"].hp == 8
    {:ok, message, change} = Actions.long_rest(world, "Sylvi")
    assert message =~ "recupera 23 pg (6 → 29"
    refute message =~ "recupera 3 pg"
    {:ok, after_rest} = change.(world)
    assert after_rest.characters["Sylvi"].hp == 29
    assert after_rest.characters["Sylvi"].con == 14
    assert after_rest.spell_slots["Sylvi"] == %{1 => 4, 2 => 2}
  end

  test "the exact eight-hour form deadline uses the restored original body" do
    world = transformed(16)
    assert world.effect_expiries["Sylvi"]["wild_shape"] == 28800
    {:ok, message, change} = Actions.long_rest(world, "Sylvi")
    assert message =~ "recupera 23 pg (6 → 29"
    {:ok, after_rest} = change.(world)
    assert after_rest.characters["Sylvi"].wild_shape == nil
    assert after_rest.characters["Sylvi"].hp == 29
  end

  test "a form with time remaining still reports the represented beast's own recovery" do
    {:ok, world} = World.apply_damage("Sylvi", 3).(transformed(18))
    assert world.effect_expiries["Sylvi"]["wild_shape"] == 32400
    {:ok, message, change} = Actions.long_rest(world, "Sylvi")
    assert message =~ "recupera 3 pg (8 → 11"
    {:ok, after_rest} = change.(world)
    assert after_rest.characters["Sylvi"].hp == 11
    assert after_rest.characters["Sylvi"].max_hp == 11
    assert after_rest.characters["Sylvi"].wild_shape.orig_hp == 6
    assert after_rest.elapsed_seconds == 28800
  end

  test "a shared night reports each expiring form's native recovery and advances only once" do
    world = transformed()

    other =
      Character.new(
        name: "Nara",
        class: "druid",
        side: "pc",
        level: 2,
        hp: 4,
        max_hp: 24,
        wild_shape_uses: 2
      )

    {:ok, world} = World.add_character(other).(world)
    {:ok, _, transform} = Actions.wild_shape(world, "Nara", "wolf")
    {:ok, world} = transform.(world)

    {:ok, message, change} =
      Actions.rest_party(world, ["Sylvi", "Nara"], "long", fn _ ->
        flunk("a long rest rolls no dice")
      end)

    assert message =~ "Sylvi hace un descanso largo y recupera 23 pg (6 → 29"
    assert message =~ "Nara hace un descanso largo y recupera 20 pg (4 → 24"
    {:ok, after_rest} = change.(world)
    assert after_rest.elapsed_seconds == 28800
    assert after_rest.characters["Sylvi"].hp == 29
    assert after_rest.characters["Nara"].hp == 24

    for name <- ["Sylvi", "Nara"] do
      assert after_rest.characters[name].wild_shape == nil
      assert after_rest.rest_state[name]["last_long_rest_start"] == 0
    end
  end
end
