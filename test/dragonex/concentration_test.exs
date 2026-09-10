defmodule Dragonex.ConcentrationTest do
  @moduledoc """
  Concentration 5e (D37): state on the caster, CON save on damage, break on
  0 hp / incapacitated-class conditions. No duration clock, no Bless +1d4.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Spell, World}

  defp always(n), do: fn _sides -> n end

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp then_apply(world, change_fn) do
    assert {:ok, w} = change_fn.(world)
    w
  end

  defp bless_spell do
    %Spell{
      name: "bless",
      level: 1,
      kind: :automatic,
      casting_ability: :wis,
      dice: nil,
      damage_type: nil,
      effect: "Up to 3 allies add 1d4 to attack rolls and saves."
    }
  end

  defp shield_of_faith_spell do
    %Spell{
      name: "shield of faith",
      level: 1,
      kind: :automatic,
      casting_ability: :wis,
      dice: nil,
      damage_type: nil,
      effect: "Target gains +2 AC for 10 minutes (concentration)."
    }
  end

  defp cleric(spells) do
    Character.new(
      name: "Cleric",
      class: "cleric",
      hp: 10,
      max_hp: 10,
      ac: 16,
      wis: 16,
      con: 10,
      side: "pc",
      spells: spells
    )
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
          con: 10,
          side: "enemy"
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
          con: 14,
          side: "pc",
          weapons: [
            %Dragonex.Weapon{
              name: "longsword",
              dice: "1d8",
              damage_type: "slashing",
              attack_ability: :str
            }
          ]
        ],
        opts
      )
    )
  end

  describe "casting a concentration spell" do
    test "bless (SRD) sets concentrating on the caster" do
      w =
        World.new()
        |> then_apply(World.add_character(cleric([bless_spell()])))
        |> then_apply(World.add_character(goblin()))

      assert {:ok, msg, change} = Actions.spell(w, "Cleric", "bless", "goblin", always(10))
      assert msg =~ "concentra en bless"
      {:ok, w2} = change.(w)
      assert w2.characters["Cleric"].concentrating == "bless"
    end

    test "a second concentration spell replaces the first" do
      w =
        World.new()
        |> then_apply(World.add_character(cleric([bless_spell(), shield_of_faith_spell()])))
        |> then_apply(World.add_character(goblin()))

      {:ok, _, change} = Actions.spell(w, "Cleric", "bless", "goblin", always(10))
      {:ok, w} = change.(w)
      assert w.characters["Cleric"].concentrating == "bless"

      {:ok, msg, change} = Actions.spell(w, "Cleric", "shield of faith", "Cleric", always(10))
      assert msg =~ "concentra en shield of faith"
      {:ok, w} = change.(w)
      assert w.characters["Cleric"].concentrating == "shield of faith"
    end

    test "a non-concentration spell does not set concentrating" do
      missile = %Spell{
        name: "magic missile",
        level: 1,
        kind: :automatic,
        casting_ability: :int,
        dice: "3d4+3",
        damage_type: "force"
      }

      wiz =
        Character.new(
          name: "Lyra",
          class: "wizard",
          hp: 7,
          max_hp: 7,
          ac: 12,
          int: 16,
          side: "pc",
          spells: [missile]
        )

      w =
        World.new()
        |> then_apply(World.add_character(wiz))
        |> then_apply(World.add_character(goblin()))

      {:ok, msg, change} = Actions.spell(w, "Lyra", "magic missile", "goblin", always(2))
      refute msg =~ "concentra"
      {:ok, w2} = change.(w)
      assert w2.characters["Lyra"].concentrating == nil
    end
  end

  describe "CON save on damage" do
    test "damage 5 → DC 10, fail drops concentration" do
      w =
        World.new()
        |> then_apply(World.add_character(fighter()))
        |> then_apply(World.add_character(goblin(concentrating: "bless")))

      # d20=10 → 15 vs CA 12 hit; d8=2 + str 3 = 5. CON d20=9 vs CD 10 fail.
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 2, 9]))

      assert msg =~ "d20 9"
      assert msg =~ "CD 10"
      assert msg =~ "pierde la concentración"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 25
      assert w2.characters["goblin"].concentrating == nil
    end

    test "damage 30 → DC 15" do
      missile = %Spell{
        name: "magic missile",
        level: 1,
        kind: :automatic,
        casting_ability: :int,
        dice: "3d4+3",
        damage_type: "force"
      }

      wiz =
        Character.new(
          name: "Lyra",
          class: "wizard",
          hp: 7,
          max_hp: 7,
          ac: 12,
          int: 16,
          side: "pc",
          spells: [missile]
        )

      w =
        World.new()
        |> then_apply(World.add_character(wiz))
        |> then_apply(World.add_character(goblin(hp: 40, max_hp: 40, concentrating: "bless")))

      # 3d4+3 with 9s = 30. CON d20=14 vs CD 15 fail.
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "magic missile", "goblin", seq([9, 9, 9, 14]))

      assert msg =~ "CD 15"
      assert msg =~ "d20 14"
      assert msg =~ "pierde la concentración"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 10
      assert w2.characters["goblin"].concentrating == nil
    end

    test "not concentrating = no save" do
      w =
        World.new()
        |> then_apply(World.add_character(fighter()))
        |> then_apply(World.add_character(goblin()))

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 2, 99]))

      refute msg =~ "concentración"
      assert Process.get(:seq) == [99]
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].concentrating == nil
    end

    test "success keeps concentration" do
      w =
        World.new()
        |> then_apply(World.add_character(fighter()))
        |> then_apply(World.add_character(goblin(concentrating: "bless")))

      # damage 5, CON d20=10 vs CD 10 success.
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 2, 10]))

      assert msg =~ "mantiene la concentración"
      assert msg =~ "CD 10"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].concentrating == "bless"
    end

    test "hp to 0 breaks without a save" do
      w =
        World.new()
        |> then_apply(World.add_character(fighter()))
        |> then_apply(World.add_character(goblin(hp: 4, max_hp: 30, concentrating: "bless")))

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 2, 99]))

      assert msg =~ "0 pg"
      assert msg =~ "pierde la concentración"
      refute msg =~ "d20 99"
      assert Process.get(:seq) == [99]
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 0
      assert w2.characters["goblin"].concentrating == nil
    end

    test "immunity (incoming 0) does not force a CON save (D38)" do
      w =
        World.new()
        |> then_apply(World.add_character(fighter()))
        |> then_apply(
          World.add_character(goblin(concentrating: "bless", damage_immunities: ["slashing"]))
        )

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 2, 99]))

      refute msg =~ "concentración"
      assert Process.get(:seq) == [99]
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30
      assert w2.characters["goblin"].concentrating == "bless"
    end
  end

  describe "Extra Attack (two hits, two saves)" do
    test "two hits that don't drop the target each force a CON save" do
      w =
        World.new()
        |> then_apply(World.add_character(fighter(level: 5)))
        |> then_apply(World.add_character(goblin(hp: 40, max_hp: 40, concentrating: "bless")))

      # L5: +6. d20=10 hit; d8=4 +3 = 7. Twice. Saves 15 (keep) then 5 (lose).
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4, 10, 4, 15, 5]))

      assert msg =~ "d20 15"
      assert msg =~ "d20 5"
      assert msg =~ "CD 10"
      assert msg =~ "mantiene la concentración"
      assert msg =~ "pierde la concentración"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 14
      assert w2.characters["goblin"].concentrating == nil
    end
  end

  describe "conditions and drop" do
    test "unconscious/incapacitated/stunned/paralyzed/petrified break without a roll" do
      for cond <- ~w(unconscious incapacitated stunned paralyzed petrified) do
        w =
          World.new()
          |> then_apply(World.add_character(goblin(concentrating: "bless")))

        {:ok, w} = World.apply_condition("goblin", cond).(w)
        assert w.characters["goblin"].concentrating == nil, cond
      end
    end

    test "prone does not break concentration" do
      w =
        World.new()
        |> then_apply(World.add_character(goblin(concentrating: "bless")))

      {:ok, w} = World.apply_condition("goblin", "prone").(w)
      assert w.characters["goblin"].concentrating == "bless"
    end

    test "clear_concentration drops the spell" do
      w =
        World.new()
        |> then_apply(World.add_character(goblin(concentrating: "bless")))

      {:ok, w} = World.clear_concentration("goblin").(w)
      assert w.characters["goblin"].concentrating == nil
    end
  end
end
