defmodule Dragonex.RecklessAttackTest do
  @moduledoc """
  Reckless Attack 5e (D44): Character.reckless, melee STR advantage, advantage
  vs the barbarian, expires at start of their next turn. No uses/day.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Weapon, World}
  alias Dragonex.Rules.Conditions

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp longsword do
    %Weapon{
      name: "longsword",
      dice: "1d8",
      damage_type: "slashing",
      attack_ability: :str
    }
  end

  defp longbow do
    %Weapon{
      name: "longbow",
      dice: "1d8",
      damage_type: "piercing",
      attack_ability: :dex,
      ranged: true
    }
  end

  defp rapier do
    %Weapon{
      name: "rapier",
      dice: "1d8",
      damage_type: "piercing",
      attack_ability: :str,
      finesse: true
    }
  end

  defp scimitar do
    %Weapon{
      name: "scimitar",
      dice: "1d6",
      damage_type: "slashing",
      attack_ability: :dex,
      finesse: true
    }
  end

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "goblin",
          class: "monster",
          hp: 30,
          max_hp: 30,
          ac: 12,
          str: 8,
          dex: 14,
          side: "enemy",
          weapons: [scimitar(), longbow()]
        ],
        opts
      )
    )
  end

  defp barbarian(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Grok",
          class: "barbarian",
          # Reckless Attack es una FEATURE de nivel 2 (RAW); L2+ en todos los
          # tests de uso.
          level: 2,
          hp: 14,
          max_hp: 14,
          ac: 14,
          str: 16,
          dex: 12,
          con: 14,
          side: "pc",
          weapons: [longsword(), longbow(), rapier()]
        ],
        opts
      )
    )
  end

  defp fighter(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          hp: 12,
          max_hp: 12,
          ac: 16,
          str: 16,
          side: "pc",
          weapons: [longsword()]
        ],
        opts
      )
    )
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  describe "Reckless Attack (D44)" do
    test "melee STR tiene ventaja" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_reckless("Grok").(w)
      assert w.characters["Grok"].reckless == true

      # +5. d20 2 y 18 → keep 18 = 23 vs CA 12; d8=4 +3 = 7.
      assert {:ok, msg, change} =
               Actions.attack(w, "Grok", "goblin", "longsword", seq([2, 18, 4]))

      assert msg =~ "ventaja"
      assert msg =~ "acierta"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 7
    end

    test "longbow no da ventaja al atacante" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_reckless("Grok").(w)

      assert {:ok, msg, _} = Actions.attack(w, "Grok", "goblin", "longbow", seq([2, 99]))
      refute msg =~ "ventaja"
      assert Process.get(:seq) == [99]
    end

    test "finesse con DEX mayor no da ventaja al atacante" do
      w = world([barbarian(str: 10, dex: 18), goblin()])
      {:ok, w} = World.start_reckless("Grok").(w)

      assert {:ok, msg, _} = Actions.attack(w, "Grok", "goblin", "rapier", seq([2, 99]))
      refute msg =~ "ventaja"
      assert Process.get(:seq) == [99]
    end

    test "ataques contra el bárbaro temerario tienen ventaja" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_reckless("Grok").(w)

      # goblin dex +2 + prof 2. d20 2 y 18 → 22 vs CA 14; d6=4 +2 = 6.
      assert {:ok, msg, change} =
               Actions.attack(w, "goblin", "Grok", "scimitar", seq([2, 18, 4]))

      assert msg =~ "ventaja"
      {:ok, w2} = change.(w)
      assert w2.characters["Grok"].hp == 14 - 6
    end

    test "ranged contra el bárbaro temerario también tiene ventaja" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_reckless("Grok").(w)

      assert {:ok, msg, _} = Actions.attack(w, "goblin", "Grok", "longbow", seq([2, 18, 4]))
      assert msg =~ "ventaja"
    end

    test "adv + desv = normal" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_reckless("Grok").(w)
      {:ok, w} = World.apply_condition("Grok", "poisoned").(w)

      assert {:ok, msg, _} = Actions.attack(w, "Grok", "goblin", "longsword", seq([2, 99]))
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
      assert Process.get(:seq) == [99]
    end

    test "fighter start_reckless error" do
      w = world([fighter()])
      assert {:error, msg} = World.start_reckless("Thane").(w)
      assert msg =~ "bárbaro"
      assert w.characters["Thane"].reckless == false
    end

    test "bárbaro L1 rechazado (Reckless Attack llega en nivel 2, RAW)" do
      w = world([barbarian(level: 1)])
      assert {:error, msg} = World.start_reckless("Grok").(w)
      assert msg =~ "nivel 2"
      assert w.characters["Grok"].reckless == false
    end

    test "bárbaro L2 ok" do
      w = world([barbarian(level: 2)])
      assert {:ok, w} = World.start_reckless("Grok").(w)
      assert w.characters["Grok"].reckless == true
    end

    test "set_current_combatant limpia reckless de ese personaje" do
      w = world([barbarian(reckless: true), goblin()])
      {:ok, w} = World.begin_combat(["Grok", "goblin"]).(w)
      assert w.characters["Grok"].reckless == true

      {:ok, w} = World.set_current_combatant("goblin").(w)
      assert w.characters["Grok"].reckless == true
      assert w.current_combatant == "goblin"

      {:ok, w} = World.set_current_combatant("Grok").(w)
      assert w.characters["Grok"].reckless == false
      assert w.current_combatant == "Grok"
    end

    test "end_combat limpia reckless" do
      w = world([barbarian(reckless: true), goblin()])
      {:ok, w} = World.begin_combat(["Grok", "goblin"]).(w)
      assert w.characters["Grok"].reckless == true
      {:ok, w} = World.end_combat().(w)
      assert w.characters["Grok"].reckless == false
      assert w.phase == :exploration
    end

    test "hp a 0 y unconscious apagan reckless" do
      w = world([barbarian(hp: 5, max_hp: 14, reckless: true)])
      {:ok, w} = World.apply_damage("Grok", 10).(w)
      assert w.characters["Grok"].hp == 0
      assert w.characters["Grok"].reckless == false

      w = world([barbarian(reckless: true)])
      {:ok, w} = World.apply_condition("Grok", "unconscious").(w)
      assert w.characters["Grok"].reckless == false
    end

    test "end_reckless es idempotente" do
      w = world([barbarian(reckless: true)])
      {:ok, w} = World.end_reckless("Grok").(w)
      assert w.characters["Grok"].reckless == false
      {:ok, w} = World.end_reckless("Grok").(w)
      assert w.characters["Grok"].reckless == false
    end

    test "Extra Attack: todos los golpes usan el mismo effective_mode" do
      w = world([barbarian(level: 5, reckless: true), goblin()])

      # dos swings con ventaja: 2,18,dmg  2,18,dmg
      assert {:ok, msg, change} =
               Actions.attack(w, "Grok", "goblin", "longsword", seq([2, 18, 4, 2, 18, 4]))

      assert msg =~ "ventaja"
      assert msg =~ "2 golpes"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 14
    end
  end

  describe "Conditions.attack_mode Reckless" do
    test "melee STR reckless → advantage" do
      a = barbarian(reckless: true)
      t = goblin()

      assert Conditions.attack_mode(a, t,
               ranged: false,
               attack_ability: :str
             ) == :advantage
    end

    test "target reckless → advantage even ranged" do
      a = goblin()
      t = barbarian(reckless: true)

      assert Conditions.attack_mode(a, t, ranged: true, attack_ability: :dex) == :advantage
    end
  end
end
