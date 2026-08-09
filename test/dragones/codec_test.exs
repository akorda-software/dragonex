defmodule Dragones.CodecTest do
  @moduledoc """
  The codec is symmetric and JSON-safe. Round-trip every shape the world takes.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Archetypes, Character, Codec, Monsters, World}

  describe "round-trip (encode -> decode)" do
    test "an empty world" do
      assert Codec.decode(Codec.encode(World.new())) == World.new()
    end

    test "the three archetypes keep every field" do
      for c <- [Archetypes.fighter(), Archetypes.wizard(), Archetypes.rogue()] do
        w = add(World.new(), World.add_character(c))
        again = Codec.decode(Codec.encode(w)).characters[c.name]

        assert %Character{} = again
        assert again.name == c.name
        assert again.side == c.side
        assert again.class == c.class
        assert again.str == c.str and again.dex == c.dex and again.cha == c.cha
        assert again.ac == c.ac and again.hp == c.hp and again.max_hp == c.max_hp
        assert again.death_saves == c.death_saves
        assert again.saving_proficiencies == c.saving_proficiencies

        assert length(again.weapons) == length(c.weapons)
        assert Enum.map(again.weapons, & &1.name) == Enum.map(c.weapons, & &1.name)
        assert hd(again.weapons).finesse == hd(c.weapons).finesse
        assert hd(again.weapons).attack_ability == hd(c.weapons).attack_ability

        assert Enum.map(again.spells, & &1.name) == Enum.map(c.spells, & &1.name)

        if c.spells != [] do
          assert hd(again.spells).kind == hd(c.spells).kind
          assert hd(again.spells).casting_ability == hd(c.spells).casting_ability
        end
      end
    end

    test "a monster (goblin) keeps its AC and weapon ability" do
      w = add(World.new(), World.add_character(Monsters.goblin()))
      g = Codec.decode(Codec.encode(w)).characters["goblin"]
      assert g.ac == 15
      assert hd(g.weapons).attack_ability == :str
      assert hd(g.weapons).finesse == true
    end

    test "combat phase, initiative and the log tuples survive" do
      w =
        World.new()
        |> add(World.add_character(Archetypes.fighter()))
        |> add(World.add_character(Monsters.goblin()))
        |> add(World.begin_combat(["Thane", "goblin"]))
        |> add(World.narrate("dm", "the goblin snarls"))

      decoded = Codec.decode(Codec.encode(w))
      assert decoded.phase == :combat
      assert decoded.initiative_order == ["Thane", "goblin"]
      assert {"dm", "the goblin snarls"} in decoded.log
      assert {"dm", "combat begins: Thane → goblin"} in decoded.log
    end

    test "death_saves tracker survives" do
      c =
        Character.new(
          name: "hero",
          class: "fighter",
          hp: 0,
          max_hp: 12,
          side: "pc",
          death_saves: %{successes: 1, fails: 2}
        )

      w = add(World.new(), World.add_character(c))

      assert Codec.decode(Codec.encode(w)).characters["hero"].death_saves ==
               %{successes: 1, fails: 2}
    end
  end

  describe "the stored form is JSON-safe" do
    test "encode yields a plain map Jason can round-trip, then decode back to structs" do
      w =
        World.new()
        |> add(World.add_character(Archetypes.wizard()))
        |> add(World.begin_combat(["Lyra"]))

      encoded = Codec.encode(w)
      refute Map.has_key?(encoded, :__struct__)

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)
      assert %World{phase: :combat} = Codec.decode(decoded_map)
      assert %Character{} = Codec.decode(decoded_map).characters["Lyra"]
    end

    test "spell_slots survives a Jason round-trip with integer level keys (regression)" do
      # Bug: JSON/jsonb stringifies the inner level keys, so a world rehydrated
      # from Postgres reported zero slots and blocked casting (World.has_slot?
      # looks up by integer). This pins the fix in Codec.decode.
      w =
        World.new()
        |> add(World.add_character(Archetypes.wizard()))
        |> World.init_spell_slots()

      caster = Archetypes.wizard().name
      # Sanity: the fresh world has a level-1 slot before serialization.
      assert World.has_slot?(w, caster, 1)

      {:ok, json} = Jason.encode(Codec.encode(w))
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode(decoded_map)

      # After a full JSON round-trip the caster can still cast a level-1 spell.
      assert World.has_slot?(decoded, caster, 1)
      # And the inner level key is an integer, not "1".
      assert is_integer(hd(Map.keys(decoded.spell_slots[caster])))
    end

    test "decode(nil) returns a pristine world instead of crashing (regression)" do
      assert %World{} = Codec.decode(nil)
      assert Codec.decode(nil) == World.new()
    end
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end
end
