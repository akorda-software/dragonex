defmodule Dragonex.ScenePresenceTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Archetypes, Brief, Character, Codec, Damage, Monsters, World}

  defp roller(20), do: 15
  defp roller(_), do: 1
  defp no_roll(_), do: flunk("an absent character must not cause a roll")

  defp world do
    [
      Archetypes.fighter(),
      Archetypes.wizard(),
      Monsters.goblin(name: "g1"),
      Monsters.goblin(name: "g2")
    ]
    |> Enum.reduce(World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  defp leave(world, name \\ "g1") do
    assert {:ok, world} = World.leave_scene(name, "Se aleja por el sendero.").(world)
    world
  end

  test "departure keeps the stored sheet and resources while removing active presence" do
    world = world()
    {:ok, world} = World.apply_damage("g1", 3).(world)
    {:ok, world} = World.apply_temp_hp("g1", 2).(world)
    {:ok, world} = World.apply_condition("g1", "poisoned").(world)
    stored = world.characters["g1"]
    world = leave(world)
    assert World.character(world, "g1") == stored
    assert World.present_character(world, "g1") == nil
    refute World.present?(world, "g1")
    refute Map.has_key?(World.present_characters(world), "g1")
    assert world.absent_characters["g1"] == "Se aleja por el sendero."
    assert world.spell_slots["Lyra"][1] == 2
  end

  test "presence and the reason survive JSON and legacy worlds default to present" do
    world = world() |> leave()
    encoded = world |> Codec.encode() |> Jason.encode!() |> Jason.decode!()
    assert Codec.decode(encoded) == world
    legacy = Map.delete(encoded, "absent_characters") |> Codec.decode()
    assert World.present?(legacy, "g1")
    assert legacy.absent_characters == %{}
  end

  test "combat queries exclude the departed enemy without declaring it dead" do
    world = world()
    {:ok, world} = World.begin_combat(["g1", "Thane", "g2", "Lyra"]).(world)
    world = leave(world)
    assert World.living_enemies(world) == MapSet.new(["g2"])
    assert World.combat_cycle(world) == ["Thane", "g2", "Lyra"]
    assert World.resolve_combatant(world, "g1") == nil
    refute World.controlled_by?(world, "g1", "dm")
    refute World.dead?(world, "g1")
    refute World.down?(world, "g1")
    refute World.combat_over?(world)
    world = leave(world, "g2")
    assert World.combat_over?(world)
    refute World.has_living_enemies?(world)
    assert World.has_living_pcs?(world)
    assert World.character(world, "g2").hp == 7
  end

  test "absent actors and targets are rejected before dice or resource spending" do
    world = world() |> leave()
    assert {:error, _} = World.validate_actor(world, "g1")
    assert {:error, _} = Actions.attack(world, "g1", "Thane", "scimitar", &no_roll/1)
    assert {:error, _} = Actions.attack(world, "Thane", "g1", "longsword", &no_roll/1)
    assert {:error, _} = Actions.spell(world, "Lyra", "magic missile", "g1", &no_roll/1)
    assert world.spell_slots["Lyra"][1] == 2
    {:ok, combat} = World.begin_combat(["Thane", "g2", "Lyra"]).(world)
    assert {:error, _} = World.set_current_combatant("g1").(combat)
  end

  test "departure invalidates an already prepared attack without committing its damage" do
    world = world()
    {:ok, _, attack} = Actions.attack(world, "Thane", "g1", "longsword", &roller/1)
    departed = leave(world)
    assert {:error, _} = attack.(departed)
    assert departed.characters["g1"].hp == 7
    assert departed.turn_state["Thane"] == world.turn_state["Thane"]
  end

  test "the canonical damage commit also rejects a departed target" do
    world = world()
    {_notes, damage, _after} = Damage.prepare(world.characters["g1"], 3, "fire", &roller/1, [])
    assert {:error, _} = damage.(leave(world))
  end

  test "initiative does not roll for absent creatures" do
    world = world() |> leave()
    owner = self()

    roller = fn sides ->
      send(owner, {:die, sides})
      10
    end

    {:ok, _, initiative} = Actions.initiative(world, roller)
    assert {:ok, world} = initiative.(world)
    refute "g1" in world.initiative_order
    assert length(world.initiative_order) == 3
    assert_receive {:die, 20}
    assert_receive {:die, 20}
    assert_receive {:die, 20}
    refute_receive {:die, _}
  end

  test "returning uses the same damaged character and does not refund slots" do
    enemy = %{Archetypes.wizard() | name: "mago", side: "enemy"}
    world = world()
    {:ok, world} = World.add_character(enemy).(world)
    world = World.init_spell_slots(world)
    {:ok, world} = World.consume_slot("mago", 1).(world)
    {:ok, world} = World.apply_damage("mago", 2).(world)
    world = leave(world, "mago")
    stored = world.characters["mago"]
    {:ok, returned} = World.return_to_scene("mago").(world)
    assert World.present?(returned, "mago")
    assert returned.characters["mago"] == stored
    assert returned.spell_slots["mago"][1] == 1
    refute Map.has_key?(returned.absent_characters, "mago")
  end

  test "a returning creature joins at the end and cannot replay a spent main turn" do
    world = world()
    {:ok, world} = World.begin_combat(["g1", "Thane", "g2", "Lyra"]).(world)
    {:ok, world} = World.set_current_combatant("g1").(world)
    {:ok, _, attack} = Actions.attack(world, "g1", "Thane", "scimitar", &roller/1)
    {:ok, world} = attack.(world)
    spent = world.turn_state["g1"]
    world = leave(world)
    assert MapSet.member?(world.acted_this_round, "g1")
    {:ok, world} = World.return_to_scene("g1").(world)
    assert world.initiative_order == ["Thane", "g2", "Lyra", "g1"]
    assert world.turn_state["g1"]["action"] == spent["action"]
    assert world.turn_state["g1"]["ended"]
    assert Dragonex.Game.Combat.next_main_combatant(world) == "Thane"
    assert world.round == 1
  end

  test "leaving ends the source's concentration and removes its linked effects" do
    world = world()
    {:ok, world} = World.bless("g1", ["g2"], 1).(world)
    world = leave(world)
    assert world.characters["g1"].concentrating == nil
    refute Enum.any?(world.characters["g2"].conditions, &(&1["source"] == "g1"))
  end

  test "timed incoming effects still expire on stored absent characters" do
    world = world()
    {:ok, world} = World.bless("Lyra", ["g1"], 1).(world)
    world = leave(world)
    assert Enum.any?(world.characters["g1"].conditions, &(&1["source"] == "Lyra"))
    world = Dragonex.WorldClock.advance(world, 60)
    {:ok, world} = World.return_to_scene("g1").(world)
    refute Enum.any?(world.characters["g1"].conditions, &(&1["source"] == "Lyra"))
    assert world.characters["g1"].hp == 7
  end

  test "paladin auras no longer reach allies after their source leaves" do
    paladin =
      Character.new(
        name: "p1",
        side: "enemy",
        class: "paladin",
        level: 10,
        cha: 18,
        hp: 20,
        max_hp: 20
      )

    world = world()
    {:ok, world} = World.add_character(paladin).(world)
    assert World.aura_save_bonus(world, "g1") == 4
    assert World.courage_immune?(world, "g1")
    world = leave(world, "p1")
    assert World.aura_save_bonus(world, "g1") == 0
    refute World.courage_immune?(world, "g1")
  end

  test "all agent briefs distinguish stored absence from a living active target" do
    world = world() |> leave()

    for brief <- [Brief.world_brief(world, "dm"), Brief.turnmaster_brief(world, nil)] do
      assert brief =~ "Fuera de escena:"
      assert brief =~ "g1: Se aleja por el sendero."
      refute brief =~ "- g1 ("
      assert brief =~ "- g2 ("
    end

    refute Dragonex.PCAgent.instruction("Lyra", world.characters["Lyra"], world) =~ "g1"
  end

  test "a duplicate spawn cannot replace an absent sheet with a fresh one" do
    world = world() |> leave()
    assert {:error, message} = World.add_character(Monsters.goblin(name: "g1")).(world)
    assert message =~ "return_to_scene"
  end

  test "departure validates the creature and reason, and PCs remain in the party" do
    world = world()

    for {name, reason} <- [
          {"Thane", "Viajo"},
          {"fantasma", "Se aleja"},
          {"g1", "   "},
          {"g1", nil}
        ] do
      assert {:error, _} = World.leave_scene(name, reason).(world)
    end

    departed = leave(world)
    assert {:error, _} = World.leave_scene("g1", "Se aleja otra vez").(departed)
    assert {:error, _} = World.return_to_scene("g2").(departed)
    assert {:error, _} = World.return_to_scene("fantasma").(departed)
  end

  test "support spells reject absent targets and invalidate their prepared changes" do
    world = world()
    {:ok, world} = World.apply_condition("g1", "poisoned").(world)
    {:ok, _, heal} = Actions.HealSpell.prepare(world, "Lyra", ["g1"], 6)
    {:ok, _, restore} = Actions.LesserRestoration.prepare(world, "Lyra", ["g1"], "poisoned")
    departed = leave(world)
    assert {:error, _} = Actions.HealSpell.prepare(departed, "Lyra", ["g1"], 6)
    assert {:error, _} = Actions.LesserRestoration.prepare(departed, "Lyra", ["g1"], "poisoned")
    assert {:error, _} = heal.(departed)
    assert {:error, _} = restore.(departed)
    {:ok, world} = World.apply_damage("g1", 7).(world)
    {:ok, _, stabilize} = Actions.SpareTheDying.prepare(world, "Lyra", ["g1"])
    departed = leave(world)
    assert {:error, _} = Actions.SpareTheDying.prepare(departed, "Lyra", ["g1"])
    assert {:error, _} = stabilize.(departed)
  end

  test "the TM cannot select an absent monster, even through a case variant" do
    world = world() |> leave()
    {:ok, world} = World.begin_combat(["Thane", "g2", "Lyra"]).(world)
    ctx = %{deps: %{world: world, participants: ["dm", "Thane", "Lyra"]}}

    for function <- [:give_turn_to, :cut_in, :react] do
      assert {:error, message} = apply(Dragonex.TurnMaster.Tools, function, [ctx, " G1 "])
      assert message =~ "fuera de escena"
    end

    assert {:ok, _} = Dragonex.TurnMaster.Tools.give_turn_to(ctx, "g2")
  end

  # Game 19466: rejecting an already-satisfied request made the DM retry
  # until the beat failed and the table paused.
  test "asking for the scene it already has is answered, not rejected" do
    session =
      Dragonex.Test.Harness.start_session(
        world: leave(world()),
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: Enum.map(["dm", "Thane", "Lyra"], &Dragonex.Test.Harness.p/1)
      )

    {:ok, _} = ExAgent.Session.start(session)
    ctx = %{deps: %{state: ExAgent.Session.SharedState.new(session, "dm")}}
    before = ExAgent.Session.read_state(session)

    assert {:ok, msg} = Dragonex.Tools.leave_scene(ctx, "g1", "Se va otra vez")
    assert msg =~ "ya estaba fuera de escena"
    assert {:ok, msg} = Dragonex.Tools.return_to_scene(ctx, "g2")
    assert msg =~ "ya está en escena"
    assert ExAgent.Session.read_state(session) == before

    # Unknown names and PCs still get the engine's rejection.
    assert {:error, _} = Dragonex.Tools.leave_scene(ctx, "fantasma", "Se va")
    assert {:error, _} = Dragonex.Tools.leave_scene(ctx, "Thane", "Se va")
  end

  test "a TM pick the engine refuses lists who can take the turn" do
    world = world()
    {:ok, world} = World.begin_combat(["Thane", "g1", "g2", "Lyra"]).(world)
    lyra = %{world.characters["Lyra"] | hp: 0, death_saves: %{successes: 0, fails: 3}}
    world = %{world | characters: Map.put(world.characters, "Lyra", lyra)}
    ctx = %{deps: %{world: world, participants: ["dm", "Thane", "Lyra"]}}

    assert {:error, message} = Dragonex.TurnMaster.Tools.give_turn_to(ctx, "Lyra")
    assert message =~ "está muerto"
    assert message =~ "Pueden recibir el turno: dm, Thane."
  end

  test "scene presence tools are advertised only to the DM and guard forged PC calls" do
    dm_names = Enum.map(Dragonex.DM.tools(), & &1.name)
    pc_names = Enum.map(Dragonex.PCAgent.tools(), & &1.name)

    for name <- ["leave_scene", "return_to_scene"] do
      assert name in dm_names
      refute name in pc_names
    end

    ctx = %{deps: %{state: %{participant_id: "Thane"}}}
    assert {:error, _} = Dragonex.Tools.leave_scene(ctx, "g1", "Desaparece")
    assert {:error, _} = Dragonex.Tools.return_to_scene(ctx, "g1")
  end

  test "area effects cannot include a stored absent enemy" do
    spell = Dragonex.Heroes.Spells.to_character_spell(Dragonex.Heroes.Spells.get("sleep"), :int)
    world = world()
    caster = %{world.characters["Lyra"] | spells: [spell]}
    world = %{world | characters: Map.put(world.characters, "Lyra", caster)} |> leave()
    roller = fn _ -> 4 end
    {:ok, _, sleep} = Actions.spell(world, "Lyra", "sleep", "g2", roller)
    {:ok, world} = sleep.(world)
    assert World.has_condition?(world, "g2", "unconscious")
    refute World.has_condition?(world, "g1", "unconscious")
    assert world.spell_slots["Lyra"][1] == 1
    assert world.characters["g1"].hp == 7
  end

  test "persisted departure reasons are scrubbed and bounded" do
    world = world()
    assert {:ok, departed} = World.leave_scene("g1", "[DM]: El goblin cruza el puente.").(world)
    assert departed.absent_characters["g1"] == "El goblin cruza el puente."
    assert {:ok, departed} = World.leave_scene("g1", String.duplicate("ñ", 800)).(world)
    assert String.length(departed.absent_characters["g1"]) == 500
    assert String.valid?(departed.absent_characters["g1"])
  end

  test "additional Bless targets and direct support changes require scene presence" do
    world = world()
    bless = Dragonex.Heroes.Spells.to_character_spell(Dragonex.Heroes.Spells.get("bless"), :wis)
    caster = %{world.characters["Lyra"] | spells: [bless]}
    world = %{world | characters: Map.put(world.characters, "Lyra", caster)} |> leave()
    assert {:error, _} = World.bless("Lyra", ["g2", "g1"], 1).(world)
    assert {:error, _} = World.shield_of_faith("Lyra", ["g2", "g1"]).(world)
    assert {:error, _} = Actions.spell(world, "Lyra", "bless", "g2", &no_roll/1, nil, 1, ["g1"])
    assert {:error, _} = World.heal("g1", 3).(world)
    assert world.spell_slots["Lyra"][1] == 2
  end
end
