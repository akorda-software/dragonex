defmodule Dragones.RestTest do
  @moduledoc """
  Short rest spends a hit die (roll + con mod); long rest full-heals.
  Both refuse downed characters.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Actions, Character, World}

  defp fixed(value), do: Dragones.Dice.always(value)

  defp world_with_hurt_fighter do
    fighter = Character.new(
      name: "hero",
      class: "fighter",
      hp: 5,
      max_hp: 12,
      ac: 16,
      str: 16, dex: 12, con: 14, int: 10, wis: 10, cha: 10,
      side: "pc"
    )

    world = World.new()
    {:ok, w} = World.add_character(fighter).(world)
    w
  end

  defp world_with_hurt_wizard do
    wizard = Character.new(
      name: "mage",
      class: "wizard",
      hp: 2,
      max_hp: 8,
      ac: 10,
      str: 8, dex: 14, con: 14, int: 16, wis: 12, cha: 10,
      side: "pc"
    )

    world = World.new()
    {:ok, w} = World.add_character(wizard).(world)
    w
  end

  describe "short_rest/3" do
    test "heals by hit_die + con_mod (fighter d10, con 14 → +2)" do
      w = world_with_hurt_fighter()

      # fixed roller(7): 1d10 = 7, + con_mod(14) = +2 → rolled 9, capped at 7 (5→12)
      {:ok, msg, change} = Actions.short_rest(w, "hero", fixed(7))

      assert msg =~ "recovers 7 hp"
      assert msg =~ "= 9"
      {:ok, w2} = change.(w)
      assert w2.characters["hero"].hp == 12
    end

    test "wizard uses d6 hit die" do
      w = world_with_hurt_wizard()

      # fixed roller(4): 1d6 = 4, + con_mod(14) = +2 → heal 6
      {:ok, msg, change} = Actions.short_rest(w, "mage", fixed(4))

      assert msg =~ "6 hp"
      {:ok, w2} = change.(w)
      assert w2.characters["mage"].hp == 2 + 6
    end

    test "caps at max_hp" do
      w = world_with_hurt_fighter()

      # fixed roller(10): 1d10 = 10, + 2 = 12, but hero is at 5/12 → only heals 7
      {:ok, _msg, change} = Actions.short_rest(w, "hero", fixed(10))
      {:ok, w2} = change.(w)
      assert w2.characters["hero"].hp == 12
    end

    test "refuses a downed character" do
      fighter = Character.new(name: "down", class: "fighter", hp: 0, max_hp: 12, side: "pc")
      {:ok, w} = World.add_character(fighter).(World.new())

      assert {:error, msg} = Actions.short_rest(w, "down", fixed(10))
      assert msg =~ "down"
    end

    test "refuses a missing character" do
      assert {:error, _} = Actions.short_rest(World.new(), "ghost", fixed(10))
    end
  end

  describe "long_rest/2" do
    test "restores to full HP" do
      w = world_with_hurt_fighter()

      {:ok, msg, change} = Actions.long_rest(w, "hero")
      assert msg =~ "full restore"

      {:ok, w2} = change.(w)
      assert w2.characters["hero"].hp == 12
    end

    test "refuses a downed character" do
      fighter = Character.new(name: "down", class: "fighter", hp: 0, max_hp: 12, side: "pc")
      {:ok, w} = World.add_character(fighter).(World.new())

      assert {:error, _} = Actions.long_rest(w, "down")
    end
  end
end
