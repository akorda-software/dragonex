defmodule Dragonex.ConditionsTest do
  @moduledoc """
  Conditions persist on the World and feed Rules.Conditions: attacks, saves
  and checks pick up advantage / disadvantage / auto-fail.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Spell, World}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp world_with_fighter_and_goblin do
    fighter =
      Character.new(
        name: "hero",
        class: "fighter",
        hp: 12,
        max_hp: 12,
        ac: 16,
        str: 16,
        dex: 12,
        con: 14,
        int: 10,
        wis: 10,
        cha: 10,
        weapons: [
          %Dragonex.Weapon{
            name: "longsword",
            dice: "1d8",
            damage_type: "slashing",
            attack_ability: :str
          }
        ],
        side: "pc"
      )

    goblin =
      Character.new(
        name: "goblin",
        class: "monster",
        hp: 7,
        max_hp: 7,
        ac: 15,
        str: 8,
        dex: 14,
        con: 10,
        int: 10,
        wis: 8,
        cha: 8,
        weapons: [
          %Dragonex.Weapon{
            name: "shortbow",
            dice: "1d6",
            damage_type: "piercing",
            attack_ability: :dex,
            ranged: true
          }
        ],
        side: "enemy"
      )

    world =
      World.new()
      |> add(World.add_character(fighter))
      |> add(World.add_character(goblin))

    world
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end

  describe "World.apply_condition / remove_condition" do
    test "apply_condition adds the condition to the character" do
      w = world_with_fighter_and_goblin()
      {:ok, w2} = World.apply_condition("goblin", "prone").(w)

      assert World.has_condition?(w2, "goblin", "prone")
      refute World.has_condition?(w2, "goblin", "poisoned")
    end

    test "apply_condition is idempotent" do
      w = world_with_fighter_and_goblin()
      {:ok, w2} = World.apply_condition("goblin", "prone").(w)
      {:ok, w3} = World.apply_condition("goblin", "prone").(w2)

      goblin = w3.characters["goblin"]
      assert Enum.count(goblin.conditions, &(&1[:condition] == "prone")) == 1
    end

    test "remove_condition removes it" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("goblin", "prone").(w)
      assert World.has_condition?(w, "goblin", "prone")

      {:ok, w} = World.remove_condition("goblin", "prone").(w)
      refute World.has_condition?(w, "goblin", "prone")
    end

    test "applying to a missing character is an error" do
      w = world_with_fighter_and_goblin()
      assert {:error, _} = World.apply_condition("ghost", "prone").(w)
    end
  end

  describe "conditions affect attack mode" do
    test "prone target: melee attacker gets advantage" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("goblin", "prone").(w)

      # d20=10: prof(2) + str_mod(3) = 15 vs AC 15 → normally hits
      # With advantage, both dice are rolled (fixed at 10) → max(10,10)=10 → hit
      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(10), :normal)

      # The message should mention "(advantage)" since prone grants it
      assert msg =~ "ventaja"
    end

    test "prone target: ranged attacker gets disadvantage" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "prone").(w)

      {:ok, msg, _} = Actions.attack(w, "goblin", "hero", "shortbow", fixed(15), :normal)
      assert msg =~ "desventaja"
    end

    test "poisoned attacker gets disadvantage" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "poisoned").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(15), :normal)
      assert msg =~ "desventaja"
    end

    test "blinded target grants advantage" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("goblin", "blinded").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(10), :normal)
      assert msg =~ "ventaja"
    end

    test "advantage + disadvantage cancel to normal" do
      w = world_with_fighter_and_goblin()
      # Attacker is poisoned (disadvantage) AND target is prone melee (advantage)
      {:ok, w} = World.apply_condition("hero", "poisoned").(w)
      {:ok, w} = World.apply_condition("goblin", "prone").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(15), :normal)
      # Should NOT mention advantage or disadvantage
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
    end

    test "model :advantage + condition disadvantage cancel to normal (regression)" do
      # Bug: the model's mode was only consulted in the fallback branch, so a
      # poisoned attacker's condition-disadvantage overrode the model's
      # :advantage instead of cancelling to :normal.
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "poisoned").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(15), :advantage)
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
    end

    test "model :disadvantage + condition advantage cancel to normal (regression)" do
      w = world_with_fighter_and_goblin()
      # Target prone + melee → condition advantage.
      {:ok, w} = World.apply_condition("goblin", "prone").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(15), :disadvantage)
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
    end

    test "prone attacker has disadvantage on melee" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "prone").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(15), :normal)
      assert msg =~ "desventaja"
    end

    test "invisible attacker has advantage" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "invisible").(w)

      {:ok, msg, _} = Actions.attack(w, "hero", "goblin", "longsword", fixed(10), :normal)
      assert msg =~ "ventaja"
    end
  end

  describe "conditions affect ability checks" do
    test "poisoned grants disadvantage on checks" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "poisoned").(w)

      {:ok, msg, _} = Actions.check(w, "hero", :str, 10, false, fixed(15), :normal)
      assert msg =~ "desventaja"
    end

    test "frightened grants disadvantage on checks" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "frightened").(w)

      {:ok, msg, _} = Actions.check(w, "hero", :wis, 10, false, fixed(15), :normal)
      assert msg =~ "desventaja"
    end

    test "poisoned + model advantage cancel to normal" do
      w = world_with_fighter_and_goblin()
      {:ok, w} = World.apply_condition("hero", "poisoned").(w)

      {:ok, msg, _} = Actions.check(w, "hero", :str, 10, false, fixed(15), :advantage)
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
    end

    test "poisoned does not affect WIS saves (RAW: checks and attacks only)" do
      w = world_with_save_caster()
      {:ok, w} = World.apply_condition("goblin", "poisoned").(w)

      {:ok, msg, _} = Actions.spell(w, "mage", "vicious mockery", "goblin", fixed(15))
      refute msg =~ "desventaja"
      refute msg =~ "automáticamente"
    end
  end

  describe "conditions affect saving throws" do
    test "restrained grants disadvantage on DEX saves" do
      w = world_with_save_caster()
      {:ok, w} = World.apply_condition("goblin", "restrained").(w)

      {:ok, msg, _} = Actions.spell(w, "mage", "acid splash", "goblin", fixed(15))
      assert msg =~ "desventaja"
    end

    test "restrained does not grant disadvantage on WIS saves" do
      w = world_with_save_caster()
      {:ok, w} = World.apply_condition("goblin", "restrained").(w)

      {:ok, msg, _} = Actions.spell(w, "mage", "vicious mockery", "goblin", fixed(15))
      refute msg =~ "desventaja"
    end

    test "paralyzed auto-fails STR/DEX saves without rolling" do
      w = world_with_save_caster()
      {:ok, w} = World.apply_condition("goblin", "paralyzed").(w)

      # seq: if the save were rolled it would consume 20 (success vs CD 13);
      # damage would then be 4. Auto-fail skips the d20 so damage is 20.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "goblin", seq([20, 4]))
      assert msg =~ "automáticamente"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20 - 20
    end

    test "stunned auto-fails DEX saves; WIS still rolls" do
      w = world_with_save_caster()
      {:ok, w} = World.apply_condition("goblin", "stunned").(w)

      {:ok, msg, _} = Actions.spell(w, "mage", "acid splash", "goblin", fixed(15))
      assert msg =~ "automáticamente"

      {:ok, wis, _} = Actions.spell(w, "mage", "vicious mockery", "goblin", fixed(15))
      refute wis =~ "automáticamente"
    end

    test "prone target: ranged spell attack has disadvantage" do
      w = world_with_save_caster()
      {:ok, w} = World.apply_condition("goblin", "prone").(w)

      {:ok, msg, _} = Actions.spell(w, "mage", "firebolt", "goblin", fixed(15))
      assert msg =~ "desventaja"
    end
  end

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp world_with_save_caster do
    mage =
      Character.new(
        name: "mage",
        class: "wizard",
        hp: 7,
        max_hp: 7,
        ac: 12,
        str: 8,
        dex: 14,
        con: 13,
        int: 16,
        wis: 12,
        cha: 10,
        side: "pc",
        spells: [
          %Spell{
            name: "acid splash",
            level: 0,
            kind: :save,
            casting_ability: :int,
            save_ability: :dex,
            dice: "1d6",
            damage_type: "acid"
          },
          %Spell{
            name: "vicious mockery",
            level: 0,
            kind: :save,
            casting_ability: :int,
            save_ability: :wis,
            dice: "1d4",
            damage_type: "psychic"
          },
          %Spell{
            name: "firebolt",
            level: 0,
            kind: :attack,
            casting_ability: :int,
            dice: "1d10",
            damage_type: "fire"
          }
        ]
      )

    goblin =
      Character.new(
        name: "goblin",
        class: "monster",
        hp: 20,
        max_hp: 20,
        ac: 15,
        str: 8,
        dex: 14,
        con: 10,
        int: 10,
        wis: 8,
        cha: 8,
        side: "enemy"
      )

    World.new()
    |> add(World.add_character(mage))
    |> add(World.add_character(goblin))
  end
end
