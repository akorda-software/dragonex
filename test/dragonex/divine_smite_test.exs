defmodule Dragonex.DivineSmiteTest do
  @moduledoc """
  Divine Smite 5e (D46): paladin pending smite_slot, first melee hit spends
  the slot and deals extra radiant. No Improved Divine Smite. No feats.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Tools, Weapon, World}
  alias ExAgent.{Session, Session.SharedState}

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

  defp paladin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Rhogar",
          class: "paladin",
          level: 2,
          hp: 18,
          max_hp: 18,
          ac: 16,
          str: 16,
          dex: 10,
          con: 14,
          cha: 14,
          side: "pc",
          weapons: [longsword(), longbow()]
        ],
        opts
      )
    )
  end

  defp goblin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "goblin",
          class: "monster",
          race: "goblinoid",
          hp: 40,
          max_hp: 40,
          ac: 12,
          side: "enemy"
        ],
        opts
      )
    )
  end

  defp world(chars) do
    chars
    |> Enum.reduce(World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  describe "World.start_smite/2" do
    test "paladín L2 slot 1 arma sin consumir casilla" do
      w = world([paladin([])])

      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      assert w.characters["Rhogar"].smite_slot == 1
      assert w.spell_slots["Rhogar"][1] == 2
    end

    test "no paladín error" do
      w = world([Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12, side: "pc")])

      assert {:error, msg} = World.start_smite("Thane", 1).(w)
      assert msg =~ "no es paladín"
    end

    test "slot fuera de 1..5 error" do
      w = world([paladin([])])

      assert {:error, msg} = World.start_smite("Rhogar", 6).(w)
      assert msg =~ "entre 1 y 5"
      assert {:error, _} = World.start_smite("Rhogar", 0).(w)
    end

    test "paladín L1 sin slots error" do
      w = world([paladin(level: 1)])

      assert {:error, msg} = World.start_smite("Rhogar", 1).(w)
      assert msg =~ "no le quedan casillas"
    end

    test "sin casillas restantes error" do
      w = world([paladin([])])
      {:ok, w} = World.consume_slot("Rhogar", 1).(w)
      {:ok, w} = World.consume_slot("Rhogar", 1).(w)

      assert {:error, msg} = World.start_smite("Rhogar", 1).(w)
      assert msg =~ "no le quedan casillas"
    end
  end

  describe "Actions.attack smite" do
    test "L2 paladín slot 1 → 2d8 radiant en hit melee" do
      w = world([paladin([]), goblin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      # prof 2 + str 3. d20=10 → 15 vs CA 12; d8=4 +3 = 7; 2d8 smite 8+8=16.
      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longsword", seq([10, 4, 8, 8]))

      assert msg =~ "acierta"
      assert msg =~ "+16 smite 2d8 radiante"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 7 - 16
      assert w2.characters["Rhogar"].smite_slot == nil
      assert w2.spell_slots["Rhogar"][1] == 1
    end

    test "miss no consume el pendiente ni la casilla" do
      w = world([paladin([]), goblin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      assert {:ok, msg, change} = Actions.attack(w, "Rhogar", "goblin", "longsword", seq([1]))
      assert msg =~ "fallo"
      refute msg =~ "smite"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40
      assert w2.characters["Rhogar"].smite_slot == 1
      assert w2.spell_slots["Rhogar"][1] == 2
    end

    test "ranged no aplica; pendiente sigue" do
      w = world([paladin([]), goblin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      # dex 0 + prof 2. d20=10 → 12 vs CA 12; d8=4 +0 = 4.
      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longbow", seq([10, 4, 99]))

      refute msg =~ "smite"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 4
      assert w2.characters["Rhogar"].smite_slot == 1
      assert w2.spell_slots["Rhogar"][1] == 2
      assert Process.get(:seq) == [99]
    end

    test "undead +1d8" do
      w = world([paladin([]), goblin(race: "undead")])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longsword", seq([10, 4, 8, 8, 8]))

      assert msg =~ "+24 smite 3d8 radiante"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 7 - 24
      assert w2.characters["Rhogar"].smite_slot == nil
      assert w2.spell_slots["Rhogar"][1] == 1
    end

    test "fiend +1d8" do
      w = world([paladin([]), goblin(race: "fiend")])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longsword", seq([10, 4, 5, 5, 5]))

      assert msg =~ "+15 smite 3d8 radiante"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 7 - 15
    end

    test "Extra Attack: el segundo swing no vuelve a gastar" do
      w = world([paladin(level: 5), goblin(hp: 80, max_hp: 80)])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      # L5 prof 3 + str 3. d20=10 → 16 vs CA 12; d8=4 +3 = 7; smite 8+8.
      # Segundo golpe: d20=10, d8=4 +3 = 7, sin smite.
      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longsword", seq([10, 4, 8, 8, 10, 4]))

      assert msg =~ "2 golpes"
      assert msg =~ "+16 smite 2d8 radiante"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 80 - 7 - 16 - 7
      assert w2.characters["Rhogar"].smite_slot == nil
      assert w2.spell_slots["Rhogar"][1] == 3
    end

    test "Extra Attack: el primer swing que acierta gasta el pendiente" do
      w = world([paladin(level: 5), goblin(hp: 80, max_hp: 80)])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)

      # miss then hit: d20=1; d20=10, d8=4, smite 8+8.
      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longsword", seq([1, 10, 4, 8, 8]))

      assert msg =~ "2 golpes"
      assert msg =~ "fallo"
      assert msg =~ "+16 smite 2d8 radiante"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 80 - 7 - 16
      assert w2.characters["Rhogar"].smite_slot == nil
      assert w2.spell_slots["Rhogar"][1] == 3
    end

    test "slot 5 cap 5d8 (no 6d8)" do
      w = world([paladin(level: 17), goblin(hp: 20, max_hp: 20)])
      {:ok, w} = World.start_smite("Rhogar", 5).(w)

      # L17 Extra Attack, but el primer golpe (7+40) tumba → no segundo swing.
      # prof 6 + str 3. d20=10 → 19 vs CA 12; d8=4 +3 = 7; 5d8 smite.
      assert {:ok, msg, change} =
               Actions.attack(w, "Rhogar", "goblin", "longsword", seq([10, 4, 8, 8, 8, 8, 8]))

      assert msg =~ "+40 smite 5d8 radiante"
      refute msg =~ "2 golpes"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 0
      assert w2.spell_slots["Rhogar"][5] == 0
    end
  end

  describe "expira sin gastar" do
    test "end_smite limpia sin consumir casilla" do
      w = world([paladin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)
      {:ok, w} = World.end_smite("Rhogar").(w)

      assert w.characters["Rhogar"].smite_slot == nil
      assert w.spell_slots["Rhogar"][1] == 2
    end

    test "set_current_combatant del paladín expira el pendiente" do
      w = world([paladin([]), goblin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)
      {:ok, w} = World.begin_combat(["Rhogar", "goblin"]).(w)
      {:ok, w} = World.set_current_combatant("Rhogar").(w)

      assert w.characters["Rhogar"].smite_slot == nil
      assert w.spell_slots["Rhogar"][1] == 2
    end

    test "set_current_combatant de otro no expira el smite del paladín" do
      w = world([paladin([]), goblin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)
      {:ok, w} = World.begin_combat(["goblin", "Rhogar"]).(w)
      {:ok, w} = World.set_current_combatant("goblin").(w)

      assert w.characters["Rhogar"].smite_slot == 1
    end

    test "end_combat limpia smite_slot" do
      w = world([paladin([]), goblin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)
      {:ok, w} = World.begin_combat(["Rhogar", "goblin"]).(w)
      {:ok, w} = World.end_combat().(w)

      assert w.characters["Rhogar"].smite_slot == nil
    end

    test "hp 0 limpia smite_slot" do
      w = world([paladin(hp: 5, max_hp: 18)])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)
      {:ok, w} = World.apply_damage("Rhogar", 5).(w)

      assert w.characters["Rhogar"].hp == 0
      assert w.characters["Rhogar"].smite_slot == nil
    end

    test "unconscious limpia smite_slot" do
      w = world([paladin([])])
      {:ok, w} = World.start_smite("Rhogar", 1).(w)
      {:ok, w} = World.apply_condition("Rhogar", "unconscious").(w)

      assert w.characters["Rhogar"].smite_slot == nil
      assert w.spell_slots["Rhogar"][1] == 2
    end
  end

  describe "Tools.divine_smite" do
    test "PC otro error" do
      rhogar = paladin([])
      vex = paladin(name: "Vex")

      game =
        start_session(
          world:
            World.init_spell_slots(World.new(characters: %{"Rhogar" => rhogar, "Vex" => vex})),
          policy: :round_robin,
          participants: [p("dm"), p("Rhogar"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Rhogar"), roller: fixed_roller(7)}}
      assert {:error, msg} = Tools.divine_smite(ctx, "Vex", 1)
      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["Vex"].smite_slot == nil
    end

    test "DM cualquiera" do
      rhogar = paladin([])

      game =
        start_session(
          world: World.init_spell_slots(World.new(characters: %{"Rhogar" => rhogar})),
          policy: :round_robin,
          participants: [p("dm"), p("Rhogar")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.divine_smite(dm, "Rhogar", 1)
      assert msg =~ "Castigo divino"
      assert Session.read_state(game).characters["Rhogar"].smite_slot == 1
      assert Session.read_state(game).spell_slots["Rhogar"][1] == 2

      assert {:ok, _} = Tools.end_smite(dm, "Rhogar")
      assert Session.read_state(game).characters["Rhogar"].smite_slot == nil
    end

    test "PC sí mismo" do
      rhogar = paladin([])

      game =
        start_session(
          world: World.init_spell_slots(World.new(characters: %{"Rhogar" => rhogar})),
          policy: :round_robin,
          participants: [p("Rhogar")]
        )

      assert {:ok, "Rhogar"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Rhogar"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.divine_smite(pc, "Rhogar", 1)
      assert msg =~ "Castigo divino"
      assert Session.read_state(game).characters["Rhogar"].smite_slot == 1
    end
  end
end
