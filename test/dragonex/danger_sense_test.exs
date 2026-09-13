defmodule Dragonex.DangerSenseTest do
  @moduledoc """
  D58 Danger Sense: barbarian L2+ has advantage on DEX saves through every
  route that consults Conditions.save_mode (spell saves here). Cancels with
  condition disadvantage; incapacitated (auto-fail set) gains nothing; WIS
  saves unchanged.
  """
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Spell, World}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end

  # Wizard L1: int 16 → save CD 13 (8 + prof 2 + mod 3).
  defp mage do
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
        }
      ]
    )
  end

  defp world_with(%Character{} = target) do
    World.new()
    |> add(World.add_character(mage()))
    |> add(World.add_character(target))
  end

  defp barbarian(level) do
    Character.new(
      name: "brar",
      class: "barbarian",
      level: level,
      hp: 20,
      max_hp: 20,
      ac: 15,
      str: 16,
      dex: 14,
      con: 14,
      int: 8,
      wis: 10,
      cha: 8,
      side: "enemy"
    )
  end

  describe "Danger Sense (D58)" do
    test "barbarian L2+: advantage on DEX saves (two dice, keep highest)" do
      w = world_with(barbarian(2))

      # Two d20s (1, 15 → keeps 15): total 15+2=17 vs CD 13 → success →
      # half of 6 = 3 → hp 17. With one die the save would be 1+2=3 → fail
      # → 6 damage, so hp 17 proves both dice were rolled and kept.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "brar", seq([1, 15, 6]))
      assert msg =~ "ventaja"

      {:ok, w2} = change.(w)
      assert w2.characters["brar"].hp == 20 - 3
    end

    test "barbarian L1: no advantage (single d20 consumed)" do
      w = world_with(barbarian(1))

      # d20 10 + 2 = 12 vs CD 13 → fail → full 6.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "brar", seq([10, 6]))
      refute msg =~ "ventaja"
      # Exactly one d20 + one damage die were consumed.
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["brar"].hp == 20 - 6
    end

    test "non-barbarian L2: no advantage" do
      w =
        world_with(
          Character.new(
            name: "figh",
            class: "fighter",
            level: 2,
            hp: 20,
            max_hp: 20,
            dex: 14,
            side: "enemy"
          )
        )

      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "figh", seq([10, 6]))
      refute msg =~ "ventaja"
      assert Process.get(:seq) == []
    end

    test "restrained disadvantage cancels Danger Sense to normal" do
      w = world_with(barbarian(2))
      {:ok, w} = World.apply_condition("brar", "restrained").(w)

      # Normal mode: single d20 (10+2=12 vs 13 → fail → full 6).
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "brar", seq([10, 6]))
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
      # One die only — advantage and disadvantage cancelled.
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["brar"].hp == 20 - 6
    end

    test "incapacitated (stunned) gains no advantage — auto-fails instead" do
      w = world_with(barbarian(2))
      {:ok, w} = World.apply_condition("brar", "stunned").(w)

      # No d20 consumed (auto-fail short-circuit); damage 6.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "brar", seq([6]))
      assert msg =~ "automáticamente"
      refute msg =~ "ventaja"
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["brar"].hp == 20 - 6
    end

    test "WIS save: Danger Sense does not apply" do
      w = world_with(barbarian(2))

      # WIS save rolls a single d20: 10 + 0 = 10 vs CD 13 → fail → full 4.
      {:ok, msg, change} = Actions.spell(w, "mage", "vicious mockery", "brar", seq([10, 4]))
      refute msg =~ "ventaja"
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["brar"].hp == 20 - 4
    end
  end
end
