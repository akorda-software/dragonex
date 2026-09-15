defmodule Dragonex.HealingAndBestiaryTest do
  @moduledoc """
  Healing spells cure instead of damage, and the bestiary provides 8 SRD monsters.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Monsters, World}

  defp fixed(value), do: Dragonex.Dice.always(value)

  describe "healing spells" do
    test "cure_wounds heals the target (not damages)" do
      cleric =
        Character.new(
          name: "Elder",
          class: "cleric",
          level: 1,
          hp: 8,
          max_hp: 8,
          ac: 16,
          str: 14,
          dex: 10,
          con: 13,
          int: 10,
          wis: 16,
          cha: 12,
          spells: [
            %Dragonex.Spell{
              name: "cure wounds",
              level: 1,
              kind: :automatic,
              casting_ability: :wis,
              dice: "1d8"
            }
          ],
          side: "pc"
        )

      fighter =
        Character.new(
          name: "Thane",
          class: "fighter",
          level: 1,
          hp: 3,
          max_hp: 12,
          ac: 16,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc"
        )

      {:ok, w} = World.add_character(cleric).(World.new())
      {:ok, w} = World.add_character(fighter).(w)
      w = World.init_spell_slots(w)

      # d8 = 5, WIS mod (16) = +3 → heal 8 total
      {:ok, msg, change} = Actions.spell(w, "Elder", "cure wounds", "Thane", fixed(5))

      assert msg =~ "se cura"
      {:ok, w2} = change.(w)
      # 3 + 8 = 11 (capped at 12? no: 3+8=11)
      assert w2.characters["Thane"].hp == 11
    end

    test "healing_word heals and consumes a slot" do
      cleric =
        Character.new(
          name: "Elder",
          class: "cleric",
          level: 1,
          hp: 8,
          max_hp: 8,
          ac: 16,
          str: 14,
          dex: 10,
          con: 13,
          int: 10,
          wis: 16,
          cha: 12,
          spells: [
            %Dragonex.Spell{
              name: "healing word",
              level: 1,
              kind: :automatic,
              casting_ability: :wis,
              dice: "1d4"
            }
          ],
          side: "pc"
        )

      ally =
        Character.new(
          name: "Ally",
          class: "fighter",
          level: 1,
          hp: 2,
          max_hp: 10,
          ac: 16,
          side: "pc"
        )

      {:ok, w} = World.add_character(cleric).(World.new())
      {:ok, w} = World.add_character(ally).(w)
      w = World.init_spell_slots(w)

      {:ok, msg, change} = Actions.spell(w, "Elder", "healing word", "Ally", fixed(3))

      assert msg =~ "se cura"
      {:ok, w2} = change.(w)
      # d4 = 3, WIS +3 → heal 6, capped at 10-2=8
      assert w2.characters["Ally"].hp == 8
      # consumed one
      assert w2.spell_slots["Elder"][1] == 1
    end

    test "healing does not affect damage spells (magic missile still damages)" do
      wizard =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 1,
          hp: 8,
          max_hp: 8,
          ac: 10,
          str: 8,
          dex: 14,
          con: 14,
          int: 16,
          wis: 12,
          cha: 10,
          spells: [
            %Dragonex.Spell{
              name: "magic missile",
              level: 1,
              kind: :automatic,
              casting_ability: :int,
              dice: "3d4+3",
              damage_type: "force"
            }
          ],
          side: "pc"
        )

      gob = Character.new(name: "gob", class: "monster", hp: 7, max_hp: 7, ac: 15, side: "enemy")

      {:ok, w} = World.add_character(wizard).(World.new())
      {:ok, w} = World.add_character(gob).(w)

      {:ok, msg, change} = Actions.spell(w, "Lyra", "magic missile", "gob", fixed(1))

      assert msg =~ "recibe"
      {:ok, w2} = change.(w)
      assert w2.characters["gob"].hp < 7
    end

    test "false life grants 1d4+4 temp_hp to the caster and consumes a slot" do
      wizard =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 1,
          hp: 8,
          max_hp: 8,
          ac: 10,
          str: 8,
          dex: 14,
          con: 14,
          int: 16,
          wis: 12,
          cha: 10,
          spells: [
            %Dragonex.Spell{
              name: "false life",
              level: 1,
              kind: :automatic,
              casting_ability: :int,
              dice: nil,
              damage_type: nil
            }
          ],
          side: "pc"
        )

      {:ok, w} = World.add_character(wizard).(World.new())
      w = World.init_spell_slots(w)

      # 1d4+4 with roller=4 → 8 temp_hp on the caster (not the target name)
      {:ok, msg, change} = Actions.spell(w, "Lyra", "false life", "Lyra", fixed(4))

      assert msg =~ "pg temporales"
      refute msg =~ "recibe"
      {:ok, w2} = change.(w)
      assert w2.characters["Lyra"].temp_hp == 8
      assert w2.characters["Lyra"].hp == 8
      assert w2.spell_slots["Lyra"][1] == 1
    end
  end

  describe "builtin overrides del SRD (dados null)" do
    # El SRD trae dice: null en espiritual weapon / prayer of healing; sin
    # override, el motor los resolvía como 0 (ataque sin daño, cura nula).
    test "spiritual weapon: builtin 1d8 force — impacto hace >0 daño" do
      assert %{dice: "1d8", kind: :attack, damage_type: "force"} =
               Dragonex.Heroes.Spells.get("spiritual weapon")

      cleric =
        Character.new(
          name: "Elder",
          class: "cleric",
          level: 3,
          hp: 20,
          max_hp: 20,
          ac: 16,
          wis: 16,
          side: "pc",
          spells: [
            Dragonex.Heroes.Spells.to_character_spell(
              Dragonex.Heroes.Spells.get("spiritual weapon"),
              :wis
            )
          ]
        )

      gob =
        Character.new(name: "gob", class: "monster", hp: 20, max_hp: 20, ac: 12, side: "enemy")

      {:ok, w} = World.add_character(cleric).(World.new())
      {:ok, w} = World.add_character(gob).(w)
      w = World.init_spell_slots(w)

      # Ataque mágico: prof 2 + SAB 3 = 5. d20 15 → 20 vs CA 12: impacta;
      # 1d8 con el mismo roller fijo 15 = 15 de daño force (> 0).
      {:ok, msg, change} = Actions.spell(w, "Elder", "spiritual weapon", "gob", fixed(15))

      assert msg =~ "impacta"
      {:ok, w2} = change.(w)
      assert w2.characters["gob"].hp == 20 - 15
      assert w2.spell_slots["Elder"][2] == 1
    end

    test "prayer of healing: builtin 2d8 — cura >0 a nivel base" do
      assert %{dice: "2d8", kind: :automatic} = Dragonex.Heroes.Spells.get("prayer of healing")

      cleric =
        Character.new(
          name: "Elder",
          class: "cleric",
          level: 3,
          hp: 20,
          max_hp: 20,
          ac: 16,
          wis: 16,
          side: "pc",
          spells: [
            Dragonex.Heroes.Spells.to_character_spell(
              Dragonex.Heroes.Spells.get("prayer of healing"),
              :wis
            )
          ]
        )

      ally = Character.new(name: "Thane", class: "fighter", hp: 2, max_hp: 20, ac: 16, side: "pc")

      {:ok, w} = World.add_character(cleric).(World.new())
      {:ok, w} = World.add_character(ally).(w)
      w = World.init_spell_slots(w)

      # 2d8 con roller 4 = 8 + SAB 3 = 11 de curación (single-target:
      # simplificación asumida).
      {:ok, msg, change} = Actions.spell(w, "Elder", "prayer of healing", "Thane", fixed(4))

      assert msg =~ "se cura"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 2 + 11
      assert w2.spell_slots["Elder"][2] == 1
    end

    test "prayer of healing a 3º suma 1d8 (2d8 + 1d8 = 3d8)" do
      cleric =
        Character.new(
          name: "Elder",
          class: "cleric",
          level: 5,
          hp: 20,
          max_hp: 20,
          ac: 16,
          wis: 16,
          side: "pc",
          spells: [
            Dragonex.Heroes.Spells.to_character_spell(
              Dragonex.Heroes.Spells.get("prayer of healing"),
              :wis
            )
          ]
        )

      ally = Character.new(name: "Thane", class: "fighter", hp: 2, max_hp: 30, ac: 16, side: "pc")

      {:ok, w} = World.add_character(cleric).(World.new())
      {:ok, w} = World.add_character(ally).(w)
      w = World.init_spell_slots(w)

      # 3d8 con roller 4 = 12 + SAB 3 = 15.
      {:ok, msg, change} =
        Actions.spell(w, "Elder", "prayer of healing", "Thane", fixed(4), nil, 3)

      assert msg =~ "(nivel 3)"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 2 + 15
      assert w2.spell_slots["Elder"][3] == 1
    end
  end

  describe "bestiary" do
    test "all 8 combat monsters are available" do
      keys = Monsters.keys()
      assert "goblin" in keys
      assert "kobold" in keys
      assert "bandit" in keys
      assert "skeleton" in keys
      assert "wolf" in keys
      assert "orc" in keys
      assert "hobgoblin" in keys
      assert "ogre" in keys
      # Plus the practice targets for arena scenarios.
      assert "training_dummy" in keys
      assert "archery_target" in keys
    end

    test "each combat monster has valid stats and weapons" do
      for key <- ~w(goblin kobold bandit skeleton wolf orc hobgoblin ogre) do
        m = Monsters.get(key).(name: key)
        assert m.side == "enemy"
        assert m.hp > 0 and m.max_hp > 0
        assert m.ac >= 10
        assert length(m.weapons) >= 1
        assert String.capitalize(key) =~ ~r/^[A-Z]/
        assert is_list(m.damage_resistances)
        assert is_list(m.damage_vulnerabilities)
        assert is_list(m.damage_immunities)
      end
    end

    test "skeleton is vulnerable to bludgeoning and immune to poison (D38)" do
      s = Monsters.skeleton()
      assert "bludgeoning" in s.damage_vulnerabilities
      assert "poison" in s.damage_immunities
      refute "slashing" in s.damage_vulnerabilities
    end

    test "practice targets are inert objects with HP and no weapons" do
      for key <- ~w(training_dummy archery_target) do
        m = Monsters.get(key).(name: key)
        assert m.side == "enemy"
        assert m.hp > 0 and m.max_hp > 0
        # No weapons — they never attack; the DM just narrates them swaying.
        assert m.weapons == []
      end
    end

    test "orc is CR 1/2 — tougher than goblin" do
      orc = Monsters.orc()
      goblin = Monsters.goblin()
      assert orc.hp > goblin.hp
      assert orc.str > goblin.str
    end

    test "ogre es CR 3 RAW — PG 59, gran garrote 2d8" do
      ogre = Monsters.ogre()
      assert ogre.hp == 59
      assert ogre.str == 19
      # 2d8 pelados: el motor suma STR +4 → 2d8+4 (RAW exacto).
      [club] = ogre.weapons
      assert club.name == "greatclub" and club.dice == "2d8"
    end

    test "monster names are customizable" do
      m = Monsters.orc(name: "Gronk")
      assert m.name == "Gronk"
    end

    test "unknown monster key returns nil" do
      assert Monsters.get("dragon") == nil
    end
  end
end
