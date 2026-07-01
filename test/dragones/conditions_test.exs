defmodule Dragones.ConditionsTest do
  @moduledoc """
  The conditions system: prone grants advantage on melee attacks and
  disadvantage on ranged; poisoned/blinded grant disadvantage to the attacker.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Actions, Character, World}

  defp fixed(value), do: Dragones.Dice.always(value)

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
          %Dragones.Weapon{
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
          %Dragones.Weapon{
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
  end
end
