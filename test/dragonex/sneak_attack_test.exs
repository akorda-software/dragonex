defmodule Dragonex.SneakAttackTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Archetypes, Character, Weapon, World}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp dagger do
    %Weapon{
      name: "dagger",
      dice: "1d4",
      damage_type: "piercing",
      attack_ability: :dex,
      finesse: true
    }
  end

  defp longsword do
    %Weapon{
      name: "longsword",
      dice: "1d8",
      damage_type: "slashing",
      attack_ability: :str
    }
  end

  defp goblin(hp \\ 30) do
    Character.new(name: "goblin", class: "monster", hp: hp, max_hp: hp, ac: 12, side: "enemy")
  end

  defp rogue(opts \\ []) do
    weapons = Keyword.get(opts, :weapons, [dagger()])
    level = Keyword.get(opts, :level, 1)
    features = Keyword.get(opts, :class_features, [])
    name = Keyword.get(opts, :name, "Vex")

    %{Archetypes.rogue(name: name) | weapons: weapons, level: level, class_features: features}
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  describe "Sneak Attack (D41)" do
    test "rogue L1 dagger + advantage aplica 1d6" do
      w = world([rogue(), goblin()])
      # 2 d20 ventaja, d4 arma, 1d6 sneak. dex +3.
      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([10, 8, 4, 5]), :advantage)

      assert msg =~ "acierta"
      assert msg =~ "incluye 5 sneak"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 12
    end

    test "rogue L1 longsword + advantage no aplica sneak" do
      w = world([rogue(weapons: [longsword()]), goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "longsword", seq([10, 8, 4, 99]), :advantage)

      refute msg =~ "sneak"
      {:ok, w2} = change.(w)
      # str 10 (+0) + prof 2; d20 10 → 12 vs CA 12; d8=4.
      assert w2.characters["goblin"].hp == 30 - 4
      assert Process.get(:seq) == [99]
    end

    test "rogue L1 dagger :normal con aliado pc consciente aplica sneak" do
      w = world([rogue(), Archetypes.fighter(name: "Thane"), goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([10, 4, 5]))

      assert msg =~ "incluye 5 sneak"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 12
    end

    test "rogue L1 dagger :normal sin aliado no aplica sneak" do
      w = world([rogue(), goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([10, 4, 99]))

      refute msg =~ "sneak"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 7
      assert Process.get(:seq) == [99]
    end

    test "rogue L1 dagger :disadvantage con aliado no aplica sneak" do
      w = world([rogue(), Archetypes.fighter(name: "Thane"), goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([18, 12, 4, 99]), :disadvantage)

      refute msg =~ "sneak"
      {:ok, w2} = change.(w)
      # keep 12 +5 = 17 vs CA 12; d4=4 +3 = 7.
      assert w2.characters["goblin"].hp == 30 - 7
      assert Process.get(:seq) == [99]
    end

    test "fighter L1 dagger + advantage no aplica sneak" do
      f = %{Archetypes.fighter() | weapons: [dagger()]}
      w = world([f, goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "dagger", seq([10, 8, 4, 99]), :advantage)

      refute msg =~ "sneak"
      {:ok, w2} = change.(w)
      # finesse max(str 3, dex 1)=3 + prof 2; d4=4 +3 = 7.
      assert w2.characters["goblin"].hp == 30 - 7
      assert Process.get(:seq) == [99]
    end

    test "rogue L5 aplica 3d6" do
      w = world([rogue(level: 5), goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([10, 10, 4, 1, 2, 3]), :advantage)

      assert msg =~ "incluye 6 sneak"
      {:ok, w2} = change.(w)
      # L5 prof 3 + dex 3; d4=4 +3 + 1+2+3 = 13.
      assert w2.characters["goblin"].hp == 30 - 13
    end

    test "crítico tira 2N d6 de sneak (no duplica el total)" do
      w = world([rogue(), goblin()])

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([20, 20, 4, 4, 2, 3]), :advantage)

      assert msg =~ "CRÍTICO"
      assert msg =~ "incluye 5 sneak"
      {:ok, w2} = change.(w)
      # 2d4=8 +3 + 2d6=5 = 16. Duplicar 1d6=2 daría 4 y dejaría [3] en la cola.
      assert w2.characters["goblin"].hp == 30 - 16
      assert Process.get(:seq) == []
    end

    test "aplica sneak sin el string class_features" do
      w = world([rogue(class_features: []), goblin()])

      assert {:ok, msg, _change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([10, 8, 4, 5]), :advantage)

      assert msg =~ "sneak"
    end
  end
end
