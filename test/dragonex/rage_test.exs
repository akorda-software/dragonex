defmodule Dragonex.RageTest do
  @moduledoc """
  Rage 5e (D42): Character.raging, melee damage bonus, B/P/S resistance overlay,
  no spells, start/end, 0 hp / unconscious / end_combat. No Reckless, no uses/day.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Spell, Weapon, World}

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

  defp firebolt do
    %Spell{
      name: "fire bolt",
      level: 0,
      kind: :attack,
      casting_ability: :int,
      dice: "1d10",
      damage_type: "fire"
    }
  end

  defp goblin(hp \\ 30) do
    Character.new(name: "goblin", class: "monster", hp: hp, max_hp: hp, ac: 12, side: "enemy")
  end

  defp barbarian(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Grok",
          class: "barbarian",
          hp: 14,
          max_hp: 14,
          ac: 14,
          str: 16,
          dex: 16,
          con: 14,
          side: "pc",
          weapons: [longsword(), longbow()],
          spells: [firebolt()]
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

  describe "Rage (D42)" do
    test "bárbaro start_rage; melee longsword hit suma +2" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_rage("Grok").(w)
      assert w.characters["Grok"].raging == true

      # str +3 + prof 2. d20=10 → 15 vs CA 12; d8=4 +3 +2 furia = 9.
      assert {:ok, msg, change} =
               Actions.attack(w, "Grok", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "acierta"
      assert msg =~ "+2 furia"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 9
    end

    test "longbow en furia no suma el bonus" do
      w = world([barbarian(), goblin()])
      {:ok, w} = World.start_rage("Grok").(w)

      # dex +3 + prof 2. d20=10 → 15 vs CA 12; d8=4 +3 = 7 (sin furia).
      assert {:ok, msg, change} =
               Actions.attack(w, "Grok", "goblin", "longbow", seq([10, 4]))

      refute msg =~ "furia"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 7
    end

    test "fighter start_rage error" do
      w = world([fighter()])
      assert {:error, msg} = World.start_rage("Thane").(w)
      assert msg =~ "bárbaro"
      assert w.characters["Thane"].raging == false
    end

    test "raging + bludgeoning 10 → 5; fire 10 → 10" do
      c = barbarian(hp: 20, max_hp: 20, raging: true)
      assert Character.incoming_damage(c, 10, "bludgeoning") == 5
      assert Character.incoming_damage(c, 10, "piercing") == 5
      assert Character.incoming_damage(c, 10, "slashing") == 5
      assert Character.incoming_damage(c, 10, "fire") == 10

      w = world([c])
      {:ok, w} = World.apply_damage("Grok", 10, "bludgeoning").(w)
      assert w.characters["Grok"].hp == 15
      {:ok, w} = World.apply_damage("Grok", 10, "fire").(w)
      assert w.characters["Grok"].hp == 5
    end

    test "spell while raging error" do
      w = world([barbarian(raging: true), goblin()])
      assert {:error, msg} = Actions.spell(w, "Grok", "fire bolt", "goblin", seq([10, 10]))
      assert msg =~ "furia"
    end

    test "start_rage rompe concentración" do
      w = world([barbarian(concentrating: "bless")])
      assert w.characters["Grok"].concentrating == "bless"
      {:ok, w} = World.start_rage("Grok").(w)
      assert w.characters["Grok"].raging == true
      assert w.characters["Grok"].concentrating == nil
    end

    test "end_combat apaga raging" do
      w = world([barbarian(raging: true), goblin()])
      {:ok, w} = World.begin_combat(["Grok", "goblin"]).(w)
      assert w.characters["Grok"].raging == true
      {:ok, w} = World.end_combat().(w)
      assert w.characters["Grok"].raging == false
      assert w.phase == :exploration
    end

    test "hp a 0 y unconscious apagan raging" do
      w = world([barbarian(hp: 5, max_hp: 14, raging: true)])
      {:ok, w} = World.apply_damage("Grok", 10).(w)
      assert w.characters["Grok"].hp == 0
      assert w.characters["Grok"].raging == false

      w = world([barbarian(raging: true)])
      {:ok, w} = World.apply_condition("Grok", "unconscious").(w)
      assert w.characters["Grok"].raging == false
    end

    test "end_rage apaga la furia" do
      w = world([barbarian(raging: true)])
      {:ok, w} = World.end_rage("Grok").(w)
      assert w.characters["Grok"].raging == false
    end

    test "Extra Attack: cada golpe melee suma el bonus" do
      w = world([barbarian(level: 5, raging: true), goblin()])

      # L5 prof 3 + str 3. d20=10 → 16 vs CA 12; d8=4 +3 +2 = 9. Dos veces.
      assert {:ok, msg, change} =
               Actions.attack(w, "Grok", "goblin", "longsword", seq([10, 4, 10, 4]))

      assert msg =~ "2 golpes"
      assert msg =~ "+2 furia"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 18
    end

    test "chequeo de Fuerza en furia tiene ventaja" do
      w = world([barbarian(raging: true)])

      # ventaja: seq 5, 15 → keep 15 +3 = 18 vs CD 10.
      assert {:ok, msg, _} = Actions.check(w, "Grok", :str, 10, false, seq([5, 15]))
      assert msg =~ "ventaja"
      assert msg =~ "éxito"
    end

    test "chequeo de Destreza en furia no tiene ventaja" do
      w = world([barbarian(raging: true)])

      assert {:ok, msg, _} = Actions.check(w, "Grok", :dex, 10, false, seq([5, 99]))
      refute msg =~ "ventaja"
      assert Process.get(:seq) == [99]
    end
  end
end
