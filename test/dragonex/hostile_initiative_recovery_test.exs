defmodule Dragonex.HostileInitiativeRecoveryTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Codec, Monsters, World}

  defp broken do
    before =
      Enum.reduce(
        [
          Archetypes.fighter(),
          Archetypes.rogue(),
          Monsters.skeleton(name: "z"),
          Monsters.goblin(name: "a")
        ],
        World.new(),
        fn c, w ->
          {:ok, next} = World.add_character(c).(w)
          next
        end
      )

    {:ok, before} = World.begin_combat(["Vex", "Thane"]).(before)
    {:ok, before} = World.set_current_combatant("Thane").(before)
    {:ok, before} = World.mark_acted("Vex").(before)
    {:ok, before} = World.apply_damage("z", 9).(before)
    before
  end

  test "missing active hostiles join at the end without replaying turns or changing resources" do
    before = broken()
    assert {:ok, recovered} = World.recover_hostile_initiative().(before)
    assert recovered.initiative_order == ["Vex", "Thane", "a", "z"]

    assert Map.drop(Map.from_struct(recovered), [:initiative_order, :log]) ==
             Map.drop(Map.from_struct(before), [:initiative_order, :log])

    assert recovered.characters["z"].hp == 4
    assert recovered.current_combatant == "Thane" and recovered.turn_owner == "Thane"
    assert recovered.acted_this_round == MapSet.new(["Vex"])
    assert {:ok, ^recovered} = World.recover_hostile_initiative().(recovered)

    assert recovered |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode() ==
             recovered

    refute World.round_complete?(recovered, World.combat_cycle(recovered))
  end

  test "absent and unconscious hostiles stay out; exploration and complete orders remain unchanged" do
    before = broken()
    {:ok, before} = World.leave_scene("a", "Se aleja.").(before)
    {:ok, before} = World.apply_damage("z", 4).(before)
    assert {:ok, ^before} = World.recover_hostile_initiative().(before)
    exploring = %{broken() | phase: :exploration}
    assert {:ok, ^exploring} = World.recover_hostile_initiative().(exploring)
    complete = %{broken() | initiative_order: ["z", "Vex", "a", "Thane"]}
    assert {:ok, ^complete} = World.recover_hostile_initiative().(complete)
  end
end
