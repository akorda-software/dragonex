defmodule Dragones.ActionsTest do
  @moduledoc """
  The intent→rules→world bridge, tested without any agent. Fixed rollers make
  every outcome a single expected value.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Actions, Archetypes, Character, World}

  defp always(n), do: fn _sides -> n end

  # A roller that pops values from a queue, so d20 and damage dice can differ.
  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  describe "attack/5" do
    setup do
      f = Archetypes.fighter()

      g =
        Character.new(name: "goblin", class: "monster", hp: 15, max_hp: 15, ac: 12, side: "enemy")

      world =
        World.new()
        |> then_apply(World.add_character(f))
        |> then_apply(World.add_character(g))

      {:ok, world: world}
    end

    test "misses on a nat 1 (no damage)", %{world: w} do
      assert {:ok, msg, change} = Actions.attack(w, "Thane", "goblin", "longsword", always(1))
      assert msg =~ "miss"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15
    end

    test "hits and applies damage on a normal hit", %{world: w} do
      # longsword +5 (str 3 + prof 2). seq: d20=10 -> 15 vs AC 12 hit; d8=4 +3 = 7.
      assert {:ok, msg, change} = Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4]))
      assert msg =~ "hits"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15 - 7
    end

    test "a crit doubles the dice, not the modifier", %{world: w} do
      # seq: d20=20 crit; 2d8=4+4 + str 3 = 11 (normal would be 4+3=7, so +4 = one extra d8).
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([20, 4, 4]))

      assert msg =~ "CRITS"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15 - 11
    end

    test "errors on unknown attacker / target / weapon", %{world: w} do
      assert {:error, "no such attacker: ghost"} =
               Actions.attack(w, "ghost", "goblin", "longsword", always(10))

      assert {:error, "no such target: ogre"} =
               Actions.attack(w, "Thane", "ogre", "longsword", always(10))

      assert {:error, _} = Actions.attack(w, "Thane", "goblin", "greatsword", always(10))
    end

    test "finesse weapon uses the higher of str/dex", %{world: w} do
      rogue = Archetypes.rogue(name: "Vex")
      w = then_apply(w, World.add_character(rogue))
      # shortsword finesse: dex 16 +3 + prof 2 = +5. seq: d20=10 hit; d6=4 +3 = 7.
      assert {:ok, _msg, change} = Actions.attack(w, "Vex", "goblin", "shortsword", seq([10, 4]))
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15 - 7
    end
  end

  describe "spell/5" do
    setup do
      wiz = Archetypes.wizard()

      g =
        Character.new(
          name: "goblin",
          class: "monster",
          hp: 20,
          max_hp: 20,
          ac: 12,
          side: "enemy",
          dex: 12
        )

      world =
        World.new()
        |> then_apply(World.add_character(wiz))
        |> then_apply(World.add_character(g))

      {:ok, world: world, wizard: wiz}
    end

    test ":automatic spell always hits (magic missile 3d4+3, roller 2 -> 6+3=9)", %{world: w} do
      assert {:ok, msg, change} = Actions.spell(w, "Lyra", "magic missile", "goblin", always(2))
      assert msg =~ "force"
      {:ok, w2} = change.(w)
      # 3d4 with roller 2 = 6, +3 = 9.
      assert w2.characters["goblin"].hp == 20 - 9
    end

    test ":attack spell hits on a high roll (firebolt 1d10)", %{world: w} do
      # firebolt spell attack: prof 2 + int 3 = +5. seq: d20=10 -> 15 vs AC 12 hit; d10=6.
      assert {:ok, msg, change} = Actions.spell(w, "Lyra", "firebolt", "goblin", seq([10, 6]))
      assert msg =~ "hits"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20 - 6
    end

    test ":attack spell misses on a low roll", %{world: w} do
      # d20 4 -> 4 + 5 = 9 vs AC 12 -> miss.
      assert {:ok, msg, change} = Actions.spell(w, "Lyra", "firebolt", "goblin", always(4))
      assert msg =~ "misses"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20
    end
  end

  describe "initiative/2" do
    test "orders by d20+dex desc and begins combat" do
      f = Archetypes.fighter()
      r = Archetypes.rogue()

      world =
        World.new()
        |> then_apply(World.add_character(f))
        |> then_apply(World.add_character(r))

      # fixed roller 10: fighter dex 12 -> 11, rogue dex 16 -> 13. rogue first.
      assert {:ok, msg, change} = Actions.initiative(world, always(10))
      assert msg =~ "Vex"
      {:ok, w2} = change.(world)
      assert w2.phase == :combat
      assert w2.initiative_order == ["Vex", "Thane"]
    end

    test "skips down (hp 0) combatants" do
      f = Archetypes.fighter()
      g = Character.new(name: "goblin", class: "m", hp: 0, max_hp: 7, side: "enemy")

      world =
        World.new()
        |> then_apply(World.add_character(f))
        |> then_apply(World.add_character(g))

      assert {:ok, _msg, change} = Actions.initiative(world, always(10))
      {:ok, w2} = change.(world)
      assert w2.initiative_order == ["Thane"]
    end
  end

  describe "death_save/3" do
    setup do
      hero = Character.new(name: "hero", class: "fighter", hp: 0, max_hp: 12, side: "pc")
      {:ok, world: then_apply(World.new(), World.add_character(hero))}
    end

    test "three fails kill the character", %{world: w} do
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(5))))
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(5))))
      refute World.dead?(w, "hero")
      {:ok, msg, change} = Actions.death_save(w, "hero", always(5))
      assert msg =~ "failure"
      {:ok, w2} = change.(w)
      assert World.dead?(w2, "hero")
    end

    test "nat 20 revives at 1 hp", %{world: w} do
      assert {:ok, msg, change} = Actions.death_save(w, "hero", always(20))
      assert msg =~ "revives"
      {:ok, w2} = change.(w)
      assert w2.characters["hero"].hp == 1
      refute World.down?(w2, "hero")
    end

    test "refuses a character that isn't down", %{world: w} do
      up = Character.new(name: "up", class: "fighter", hp: 10, max_hp: 12, side: "pc")
      w = then_apply(w, World.add_character(up))
      assert {:error, "up is not down (hp 10)"} = Actions.death_save(w, "up", always(10))
    end
  end

  describe "roll/4" do
    test "normal sum" do
      assert {:ok, "rolled 2d6 = 8"} = Actions.roll(2, 6, :normal, always(4))
    end

    test "advantage keeps the higher of two" do
      # roller always 4 -> both 4 -> kept 4.
      assert {:ok, msg} = Actions.roll(1, 20, :advantage, always(4))
      assert msg =~ "= 4"
    end
  end

  describe "heal/4" do
    test "applies the rolled healing, capped at max_hp" do
      hero = Character.new(name: "hero", class: "fighter", hp: 10, max_hp: 12, side: "pc")
      w = then_apply(World.new(), World.add_character(hero))

      # 1d8 roller 8 -> 8, but only 2 hp to max -> applied 2.
      assert {:ok, msg, change} = Actions.heal(w, "hero", "1d8", always(8))
      assert msg =~ "healed for 2 hp"
      {:ok, w2} = change.(w)
      assert w2.characters["hero"].hp == 12
    end

    test "clears the death-save tracker when reviving" do
      down =
        Character.new(
          name: "down",
          class: "fighter",
          hp: 0,
          max_hp: 12,
          side: "pc",
          death_saves: %{successes: 1, fails: 2}
        )

      w = then_apply(World.new(), World.add_character(down))

      assert {:ok, _msg, change} = Actions.heal(w, "down", "1d8+3", always(2))
      {:ok, w2} = change.(w)
      # 1d8(2)+3 = 5 -> hp 5, saves reset.
      assert w2.characters["down"].hp == 5
      assert w2.characters["down"].death_saves == %{successes: 0, fails: 0}
    end

    test "errors on an unknown target" do
      assert {:error, "no such character: ghost"} =
               Actions.heal(World.new(), "ghost", "1d8", always(5))
    end
  end

  describe "check/6 (ability check)" do
    test "reports d20 + modifier vs the DM's DC, with success/failure" do
      f = Archetypes.fighter()
      w = then_apply(World.new(), World.add_character(f))

      # STR 16 (+3). d20 12 -> 15 vs DC 15 -> success.
      assert {:ok, msg, change} = Actions.check(w, "Thane", :str, 15, false, always(12))
      assert msg =~ "Strength check"
      assert msg =~ "d20 12"
      assert msg =~ "+3"
      assert msg =~ "= 15"
      assert msg =~ "DC 15"
      assert msg =~ "success"
      # A check has no world side-effect.
      {:ok, w2} = change.(w)
      assert w2 == w
    end

    test "no proficiency in the message when untrained" do
      f = Archetypes.fighter()
      w = then_apply(World.new(), World.add_character(f))
      {:ok, msg, _} = Actions.check(w, "Thane", :dex, 12, false, always(10))
      refute msg =~ "prof"
    end

    test "errors on an unknown character" do
      assert {:error, "no such character: ghost"} =
               Actions.check(World.new(), "ghost", :str, 10, false, always(10))
    end
  end

  # helpers ----------------------------------------------------------------
  defp then_apply(world, change_fn) do
    assert {:ok, w} = change_fn.(world)
    w
  end

  defp then_change({:ok, _msg, change}), do: change
end
