defmodule Dragonex.BriefClockContextTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Archetypes, Brief, Codec, Monsters, Rest, World}

  test "the explicit exploration clock instruction belongs only to the DM, outside combat" do
    world = after_night()
    assert Brief.world_brief(world, "dm") =~ "advance_time"

    for actor <- ["Thane", "Lyra"] do
      refute Brief.world_brief(world, actor) =~ "advance_time"
    end

    {:ok, combat} = World.begin_combat(["Thane", "Lyra", "g1"]).(world)
    refute Brief.world_brief(combat, "dm") =~ "advance_time"
    assert Brief.turnmaster_brief(world, "Thane") =~ "Tiempo del mundo"
    refute Brief.turnmaster_brief(world, "Thane") =~ "advance_time"
  end

  defp after_night do
    world = World.new(scene: "El goblin aún no aparece. El encargo está pendiente.")

    world =
      Enum.reduce(
        [Archetypes.fighter(), Archetypes.wizard(), Monsters.goblin(name: "g1")],
        world,
        fn c, w ->
          {:ok, w} = World.add_character(c).(w)
          w
        end
      )
      |> World.init_spell_slots()

    {:ok, world} = World.apply_damage("g1", 7).(world)
    {:ok, world} = World.add_fact("El encargo terminó y la recompensa está pagada.").(world)
    {:ok, world} = World.advance_time(3600).(world)
    {:ok, _, rest} = Actions.rest_party(world, ["Thane", "Lyra"], "long", fn _ -> 1 end)
    {:ok, world} = rest.(world)
    world
  end

  test "the actual world clock and remaining daily wait agree with rest validation after Codec" do
    world =
      after_night() |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()

    assert world.elapsed_seconds == 32400
    assert Rest.long_rest_wait(world, "Thane") == 57600
    assert {:error, message} = Rest.validate(world, "Thane", :long)
    assert message =~ "24 horas"
    {:ok, before} = World.advance_time(57599).(world)
    assert Rest.long_rest_wait(before, "Thane") == 1
    assert {:error, _} = Rest.validate(before, "Thane", :long)
    {:ok, available} = World.advance_time(1).(before)
    assert Rest.long_rest_wait(available, "Thane") == 0
    assert Rest.validate(available, "Thane", :long) == :ok
  end

  test "the actor brief exposes factual time and labels the old description before current facts" do
    world = after_night()
    brief = Brief.world_brief(world, "dm")
    assert brief =~ "Tiempo del mundo: 32400 s transcurridos"
    assert brief =~ "Escena registrada: #{world.scene}"
    assert brief =~ "prevalecen los hechos canónicos y el estado actual"
    assert brief =~ "Descanso largo: beneficio disponible en 57600 s"
    assert brief =~ "El encargo terminó y la recompensa está pagada."
    assert brief =~ "g1"
    assert brief =~ "[CAÍDO]"
    {scene_at, _} = :binary.match(brief, "Escena registrada:")
    {facts_at, _} = :binary.match(brief, "Hechos establecidos")
    assert scene_at < facts_at
    assert world.scene == "El goblin aún no aparece. El encargo está pendiente."
  end

  test "the TurnMaster receives the same clock and canonical facts after the registered description" do
    world = after_night()
    brief = Brief.turnmaster_brief(world, "dm", ["Thane", "Lyra"])
    assert brief =~ "Tiempo del mundo: 32400 s transcurridos"
    assert brief =~ "Escena registrada: #{world.scene}"
    assert brief =~ "El encargo terminó y la recompensa está pagada."
    {scene_at, _} = :binary.match(brief, "Escena registrada:")
    {facts_at, _} = :binary.match(brief, "Hechos establecidos")
    {state_at, _} = :binary.match(brief, "Estado:")
    assert scene_at < facts_at and facts_at < state_at
  end

  test "legacy entries do not invent a wait and an unavailable actor is never offered a rest" do
    world = World.new(characters: %{"Thane" => Archetypes.fighter()})
    assert Rest.long_rest_wait(world, "Thane") == 0
    assert Brief.world_brief(world, "Thane") =~ "Descanso largo: disponible fuera de combate"
    assert Brief.world_brief(world, "Thane") =~ "Tiempo del mundo: 0 s transcurridos"
    {:ok, downed} = World.apply_damage("Thane", 99).(world)
    assert Brief.world_brief(downed, "dm") =~ "Descanso largo: bloqueado"
    refute Brief.world_brief(downed, "dm") =~ "Descanso largo: disponible"
    {:ok, combat} = World.begin_combat(["Thane"]).(world)
    assert Brief.world_brief(combat, "Thane") =~ "Descanso largo: bloqueado"
    refute Brief.world_brief(combat, "Thane") =~ "Descanso largo: disponible"
    unknown = %{world | rest_state: %{"Thane" => %{"last_long_rest_start" => "sin registro"}}}
    assert Rest.long_rest_wait(unknown, "Thane") == 0
  end
end
