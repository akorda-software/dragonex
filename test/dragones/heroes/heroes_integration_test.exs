defmodule Dragones.HeroesIntegrationTest do
  @moduledoc """
  Characters produced by the creator survive the Codec round-trip and work
  inside the combat engine (Actions.attack / Actions.spell) with 5e-correct
  results.

  Uses the same deterministic-roller pattern as test/dragones/flows/combat_test.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Actions, Codec, Heroes, Monsters, World}

  # ===================================================== codec round-trip

  describe "Codec round-trip preserves every field" do
    test "elf wizard survives encode → decode" do
      {:ok, lyra} = Heroes.build(%{
        name: "Lyra", race: "elf", subrace: "high elf",
        class: "wizard", background: "sage"
      })

      world = add(World.new(), World.add_character(lyra))
      decoded = Codec.decode(Codec.encode(world)).characters["Lyra"]

      assert decoded.name == lyra.name
      assert decoded.race == lyra.race
      assert decoded.class == lyra.class
      assert decoded.str == lyra.str
      assert decoded.int == lyra.int
      assert decoded.hp == lyra.hp
      assert decoded.max_hp == lyra.max_hp
      assert decoded.ac == lyra.ac
      assert decoded.speed == lyra.speed
      assert decoded.saving_proficiencies == lyra.saving_proficiencies

      assert length(decoded.weapons) == length(lyra.weapons)
      assert hd(decoded.weapons).name == hd(lyra.weapons).name
      assert hd(decoded.weapons).attack_ability == hd(lyra.weapons).attack_ability

      assert length(decoded.spells) == length(lyra.spells)
      assert hd(decoded.spells).casting_ability == hd(lyra.spells).casting_ability
      assert hd(decoded.spells).kind == hd(lyra.spells).kind
    end

    test "dwarf fighter survives a JSON round-trip (Jason encode + decode)" do
      {:ok, grim} = Heroes.build(%{
        name: "Grim", race: "dwarf", subrace: "mountain",
        class: "fighter", background: "soldier"
      })

      world = add(World.new(), World.add_character(grim))
      encoded = Codec.encode(world)

      refute Map.has_key?(encoded, :__struct__)

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode(decoded_map).characters["Grim"]
      assert decoded.str == grim.str
      assert decoded.ac == grim.ac
      assert decoded.hp == grim.hp
    end

    test "every class + race combination survives codec round-trip" do
      combos = [
        {"human", nil, "barbarian"},
        {"halfling", "stout", "rogue"},
        {"dragonborn", nil, "paladin"},
        {"half-orc", nil, "monk"},
        {"tiefling", nil, "warlock"},
        {"gnome", "rock gnome", "bard"},
        {"half-elf", nil, "sorcerer"},
        {"elf", "dark elf", "cleric"},
        {"dwarf", "hill", "druid"},
        {"elf", "wood elf", "ranger"}
      ]

      for {race, sub, class} <- combos do
        {:ok, c} = Heroes.build(%{
          name: "hero", race: race, subrace: sub,
          class: class, background: "soldier"
        })

        world = add(World.new(), World.add_character(c))
        decoded = Codec.decode(Codec.encode(world)).characters["hero"]

        assert decoded.str == c.str, "#{race}/#{class} str mismatch"
        assert decoded.int == c.int, "#{race}/#{class} int mismatch"
        assert decoded.hp == c.hp, "#{race}/#{class} hp mismatch"
        assert decoded.ac == c.ac, "#{race}/#{class} ac mismatch"
        assert length(decoded.weapons) == length(c.weapons)
        assert length(decoded.spells) == length(c.spells)
      end
    end
  end

  # =========================================== combat engine integration

  describe "a built character fights in the combat engine" do
    test "fighter attacks a goblin and deals damage (hit)" do
      {:ok, hero} = Heroes.build(%{
        name: "Hero", race: "dwarf", subrace: "mountain",
        class: "fighter", background: "soldier"
      })

      world =
        World.new()
        |> add(World.add_character(hero))
        |> add(World.add_character(Monsters.goblin()))

      # d20=15: prof(2) + str_mod(3) + 15 = 20 vs goblin AC 15 → hit
      {:ok, msg, change} = Actions.attack(world, "Hero", "goblin", "longsword", fixed(15), :normal)

      assert msg =~ "hits"
      new_world = elem(change.(world), 1)
      assert new_world.characters["goblin"].hp < 7
    end

    test "fighter misses on a low roll" do
      {:ok, hero} = Heroes.build(%{
        name: "Hero", race: "human", class: "fighter", background: "soldier"
      })

      world =
        World.new()
        |> add(World.add_character(hero))
        |> add(World.add_character(Monsters.goblin()))

      {:ok, msg, change} = Actions.attack(world, "Hero", "goblin", "longsword", fixed(2), :normal)

      assert msg =~ "miss"
      new_world = elem(change.(world), 1)
      assert new_world.characters["goblin"].hp == 7
    end

    test "wizard casts fire bolt (spell attack) at a goblin" do
      {:ok, lyra} = Heroes.build(%{
        name: "Lyra", race: "elf", subrace: "high elf",
        class: "wizard", background: "sage"
      })

      world =
        World.new()
        |> add(World.add_character(lyra))
        |> add(World.add_character(Monsters.goblin()))

      # fire bolt is a spell attack: d20 + prof(2) + int_mod(3) = d20 + 5
      # d20=15 → total 20 vs goblin AC 15 → hit, 1d10 fire
      {:ok, msg, change} = Actions.spell(world, "Lyra", "fire bolt", "goblin", fixed(15))

      assert msg =~ "fire bolt"
      assert msg =~ "hits"
      new_world = elem(change.(world), 1)
      assert new_world.characters["goblin"].hp < 7
    end

    test "wizard casts magic missile (automatic, always hits)" do
      {:ok, lyra} = Heroes.build(%{
        name: "Lyra", race: "elf", subrace: "high elf",
        class: "wizard", background: "sage"
      })

      world =
        World.new()
        |> add(World.add_character(lyra))
        |> add(World.add_character(Monsters.goblin()))

      # magic missile is :automatic — always hits, 3d4+3 force
      {:ok, msg, change} = Actions.spell(world, "Lyra", "magic missile", "goblin", fixed(1))

      assert msg =~ "magic missile"
      new_world = elem(change.(world), 1)
      # fixed roller(1) → 3d4 = 3, +3 = 6 damage
      assert new_world.characters["goblin"].hp == 7 - 6
    end

    test "cleric casts sacred flame (DEX save cantrip)" do
      {:ok, priest} = Heroes.build(%{
        name: "Elder", race: "human", class: "cleric", background: "acolyte"
      })

      world =
        World.new()
        |> add(World.add_character(priest))
        |> add(World.add_character(Monsters.goblin()))

      # sacred flame: goblin saves DEX vs DC 8+prof(2)+wis_mod(3) = 13
      # goblin dex_mod(14)=+2, not proficient → d20 + 2 vs DC 13
      # d20=5 → 7 < 13 → fails → full damage 1d8
      {:ok, msg, change} = Actions.spell(world, "Elder", "sacred flame", "goblin", fixed(5))

      assert msg =~ "sacred flame"
      assert msg =~ "fails"
      new_world = elem(change.(world), 1)
      assert new_world.characters["goblin"].hp < 7
    end

    test "goblin attacks the built fighter (saves work on built characters)" do
      {:ok, hero} = Heroes.build(%{
        name: "Hero", race: "human", class: "fighter", background: "soldier"
      })

      world =
        World.new()
        |> add(World.add_character(hero))
        |> add(World.add_character(Monsters.goblin()))

      # goblin scimitar: d20 + prof(2) + dex/finesse mod(2) = d20 + 4
      # d20=18 → 22 vs fighter AC 18 → hit
      {:ok, msg, change} = Actions.attack(world, "goblin", "Hero", "scimitar", fixed(18), :normal)

      assert msg =~ "hits"
      new_world = elem(change.(world), 1)
      assert new_world.characters["Hero"].hp < hero.hp
    end

    test "a nat-20 is a critical hit" do
      {:ok, hero} = Heroes.build(%{
        name: "Hero", race: "human", class: "fighter", background: "soldier"
      })

      world =
        World.new()
        |> add(World.add_character(hero))
        |> add(World.add_character(Monsters.goblin()))

      {:ok, msg, _change} = Actions.attack(world, "Hero", "goblin", "longsword", fixed(20), :normal)

      assert msg =~ "CRITS"
    end
  end

  # ====================================================== helpers

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end

  defp fixed(value), do: Dragones.Dice.always(value)
end
