defmodule Dragonex.ActionsTest do
  @moduledoc """
  The intent→rules→world bridge, tested without any agent. Fixed rollers make
  every outcome a single expected value.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Archetypes, Character, Monsters, World}

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
      assert msg =~ "fallo"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15
    end

    test "hits and applies damage on a normal hit", %{world: w} do
      # longsword +5 (str 3 + prof 2). seq: d20=10 -> 15 vs AC 12 hit; d8=4 +3 = 7.
      assert {:ok, msg, change} = Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4]))
      assert msg =~ "acierta"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15 - 7
    end

    test "a crit doubles the dice, not the modifier", %{world: w} do
      # seq: d20=20 crit; 2d8=4+4 + str 3 = 11 (normal would be 4+3=7, so +4 = one extra d8).
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([20, 4, 4]))

      assert msg =~ "CRÍTICO"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15 - 11
    end

    test "errors on unknown attacker / target / weapon", %{world: w} do
      assert {:error, "no existe el atacante: ghost"} =
               Actions.attack(w, "ghost", "goblin", "longsword", always(10))

      assert {:error, "no existe el objetivo: ogre"} =
               Actions.attack(w, "Thane", "ogre", "longsword", always(10))

      assert {:error, _} = Actions.attack(w, "Thane", "goblin", "greatsword", always(10))
    end

    test "fuzzy-matches the weapon name (case/space-insensitive, substring)", %{world: w} do
      # The LLM often says "sword" for "longsword" or varies casing/spacing.
      # Each resolves to the longsword; d20=10 -> 15 vs AC 12 hit, d8=4 +3 = 7.
      for weapon <- ["sword", "Longsword", "LONG SWORD"] do
        assert {:ok, msg, _change} = Actions.attack(w, "Thane", "goblin", weapon, seq([10, 4]))
        assert msg =~ "acierta"
      end
    end

    test "logs a structured attack group + damage group when given a RollLog", %{world: w} do
      alias Dragonex.RollLog
      {:ok, rec} = RollLog.start()
      log = %RollLog{base: seq([10, 4]), recorder: rec}

      # seq: d20=10 -> 15 vs AC 12 hit; d8=4 +3 = 7.
      assert {:ok, _msg, _change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4]), :normal, log)

      [atk, dmg] = RollLog.entries(rec)
      assert atk.who == "Thane" and atk.kind == :attack
      assert atk.dice == [[20, 10]] and atk.total == 15 and atk.against == ["ac", 12]
      assert atk.outcome == :hit

      assert dmg.kind == :damage
      assert dmg.dice == [[8, 4]] and dmg.total == 7

      RollLog.stop(rec)
    end

    test "finesse weapon uses the higher of str/dex" do
      rogue = Archetypes.rogue(name: "Vex")

      g =
        Character.new(name: "goblin", class: "monster", hp: 15, max_hp: 15, ac: 12, side: "enemy")

      w =
        World.new()
        |> then_apply(World.add_character(rogue))
        |> then_apply(World.add_character(g))

      # sin aliado ni ventaja: no sneak. shortsword: dex +3 + prof 2. d20=10 hit; d6=4 +3 = 7.
      assert {:ok, _msg, change} = Actions.attack(w, "Vex", "goblin", "shortsword", seq([10, 4]))
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 15 - 7
    end
  end

  describe "Extra Attack (D35)" do
    test "fighter L5 resuelve 2 golpes (N sale del nivel, no del jsonb)" do
      f = %{Archetypes.fighter() | level: 5}
      refute "extra_attack" in f.class_features

      g =
        Character.new(name: "goblin", class: "monster", hp: 30, max_hp: 30, ac: 12, side: "enemy")

      w =
        World.new()
        |> then_apply(World.add_character(f))
        |> then_apply(World.add_character(g))

      # L5: prof 3 + str 3 = +6. d20=10 → 16 vs CA 12 hit; d8=4 +3 = 7. Dos veces.
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4, 10, 4]))

      assert msg =~ "2 golpes"
      assert msg =~ "acierta"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 14
    end

    test "wizard L5 resuelve 1 golpe" do
      wiz = %{Archetypes.wizard() | level: 5}

      g =
        Character.new(name: "goblin", class: "monster", hp: 20, max_hp: 20, ac: 12, side: "enemy")

      w =
        World.new()
        |> then_apply(World.add_character(wiz))
        |> then_apply(World.add_character(g))

      # seq corto: un segundo golpe agotaría la cola y fallaría.
      assert {:ok, msg, change} =
               Actions.attack(w, "Lyra", "goblin", "quarterstaff", seq([10, 4]))

      refute msg =~ "2 golpes"
      {:ok, w2} = change.(w)
      # str 8 (−1) + prof 3 = +2. d20=10 → 12 vs CA 12 hit; d6=4 −1 = 3.
      assert w2.characters["goblin"].hp == 20 - 3
    end

    test "si el primer golpe mata, el segundo no tira ni aplica daño" do
      f = %{Archetypes.fighter() | level: 5}

      g =
        Character.new(name: "goblin", class: "monster", hp: 5, max_hp: 15, ac: 12, side: "enemy")

      w =
        World.new()
        |> then_apply(World.add_character(f))
        |> then_apply(World.add_character(g))

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4, 10, 4]))

      refute msg =~ "2 golpes"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 0
      # El segundo d20+d8 no se consumió.
      assert Process.get(:seq) == [10, 4]
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
      assert msg =~ "impacta"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20 - 6
    end

    test ":attack spell misses on a low roll", %{world: w} do
      # d20 4 -> 4 + 5 = 9 vs AC 12 -> miss.
      assert {:ok, msg, change} = Actions.spell(w, "Lyra", "firebolt", "goblin", always(4))
      assert msg =~ "falla contra"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20
    end

    test ":attack spell crit (nat 20) doubles the damage dice (regression)", %{world: w} do
      # firebolt 1d10. seq: d20=20 (crit), then two d10 rolls of 6 each = 12.
      # Before the fix the dice were rolled once (6) even on a nat 20.
      assert {:ok, _msg, change} = Actions.spell(w, "Lyra", "firebolt", "goblin", seq([20, 6, 6]))
      {:ok, w2} = change.(w)
      # 6 + 6 = 12 damage on the crit (goblin started at 20 hp).
      assert w2.characters["goblin"].hp == 20 - 12
    end
  end

  describe "downed actor guards (hp <= 0 cannot act)" do
    setup do
      downed =
        Character.new(
          name: "Thane",
          class: "fighter",
          hp: 0,
          max_hp: 12,
          ac: 16,
          side: "pc",
          str: 16
        )

      g =
        Character.new(name: "goblin", class: "monster", hp: 7, max_hp: 7, ac: 12, side: "enemy")

      world =
        World.new()
        |> then_apply(World.add_character(downed))
        |> then_apply(World.add_character(g))

      {:ok, world: world}
    end

    test "a downed attacker cannot make a weapon attack", %{world: w} do
      assert {:error, msg} = Actions.attack(w, "Thane", "goblin", "longsword", always(10))
      assert msg =~ "caído"
    end

    test "a downed caster cannot cast a spell", %{world: w} do
      assert {:error, msg} = Actions.spell(w, "Thane", "firebolt", "goblin", always(10))
      assert msg =~ "caído"
    end

    test "a downed character cannot make an ability check", %{world: w} do
      assert {:error, msg} = Actions.check(w, "Thane", :str, 10, false, always(10))
      assert msg =~ "caído"
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

    test "same total, higher DEX score goes first" do
      low =
        Character.new(name: "Aldo", class: "fighter", hp: 10, max_hp: 10, dex: 16)

      high =
        Character.new(name: "Zed", class: "fighter", hp: 10, max_hp: 10, dex: 17)

      world =
        World.new()
        |> then_apply(World.add_character(low))
        |> then_apply(World.add_character(high))

      # both mod +3, roller 10 → total 13; Zed wins on DEX 17 > 16 (not name).
      assert {:ok, _msg, change} = Actions.initiative(world, always(10))
      {:ok, w2} = change.(world)
      assert w2.initiative_order == ["Zed", "Aldo"]
    end

    test "same total and DEX breaks ties by name ascending" do
      zed = Character.new(name: "Zed", class: "fighter", hp: 10, max_hp: 10, dex: 14)
      aldo = Character.new(name: "Aldo", class: "fighter", hp: 10, max_hp: 10, dex: 14)

      world =
        World.new()
        |> then_apply(World.add_character(zed))
        |> then_apply(World.add_character(aldo))

      assert {:ok, _msg, change} = Actions.initiative(world, always(10))
      {:ok, w2} = change.(world)
      assert w2.initiative_order == ["Aldo", "Zed"]
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
      assert msg =~ "fallo"
      {:ok, w2} = change.(w)
      assert World.dead?(w2, "hero")
    end

    test "nat 20 revives at 1 hp", %{world: w} do
      assert {:ok, msg, change} = Actions.death_save(w, "hero", always(20))
      assert msg =~ "revive"
      {:ok, w2} = change.(w)
      assert w2.characters["hero"].hp == 1
      refute World.down?(w2, "hero")
    end

    test "refuses a character that isn't down", %{world: w} do
      up = Character.new(name: "up", class: "fighter", hp: 10, max_hp: 12, side: "pc")
      w = then_apply(w, World.add_character(up))
      assert {:error, "up no está caído (pg 10)"} = Actions.death_save(w, "up", always(10))
    end

    test "refuses a dead character (3 fails) so death saves don't loop forever", %{world: w} do
      # Three failed saves kill the character...
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(5))))
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(5))))
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(5))))
      assert World.dead?(w, "hero")

      # ...and the engine must NOT accept any further death save on a corpse.
      assert {:error, msg} = Actions.death_save(w, "hero", always(10))
      assert msg =~ "muerto"
    end

    test "refuses a stable character (3 successes) so death saves don't loop", %{world: w} do
      # Three successful saves (d20 10 >= 10) stabilize the character.
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(10))))
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(10))))
      w = then_apply(w, then_change(Actions.death_save(w, "hero", always(10))))

      # The engine must NOT accept further death saves on a stable character.
      assert {:error, msg} = Actions.death_save(w, "hero", always(10))
      assert msg =~ "estable"
    end
  end

  describe "roll/4" do
    test "normal sum" do
      assert {:ok, "tirada 2d6 = 8"} = Actions.roll(2, 6, :normal, always(4))
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
      assert msg =~ "se cura 2 pg"
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
      assert {:error, "no existe el personaje: ghost"} =
               Actions.heal(World.new(), "ghost", "1d8", always(5))
    end
  end

  describe "check/6 (ability check)" do
    test "reports d20 + modifier vs the DM's DC, with success/failure" do
      f = Archetypes.fighter()
      w = then_apply(World.new(), World.add_character(f))

      # STR 16 (+3). d20 12 -> 15 vs DC 15 -> success.
      assert {:ok, msg, change} = Actions.check(w, "Thane", :str, 15, false, always(12))
      assert msg =~ "chequeo de Fuerza"
      assert msg =~ "d20 12"
      assert msg =~ "+3"
      assert msg =~ "= 15"
      assert msg =~ "CD 15"
      assert msg =~ "éxito"
      # A check has no world side-effect.
      {:ok, w2} = change.(w)
      assert w2 == w
    end

    test "no proficiency in the message when untrained" do
      f = Archetypes.fighter()
      w = then_apply(World.new(), World.add_character(f))
      {:ok, msg, _} = Actions.check(w, "Thane", :dex, 12, false, always(10))
      refute msg =~ "competencia"
    end

    test "errors on an unknown character" do
      assert {:error, "no existe el personaje: ghost"} =
               Actions.check(World.new(), "ghost", :str, 10, false, always(10))
    end
  end

  describe "damage types (D38)" do
    test "longsword slashing vs skeleton vulnerability doubles" do
      f = Archetypes.fighter()

      skel =
        Character.new(
          name: "skeleton",
          class: "monster",
          hp: 30,
          max_hp: 30,
          ac: 12,
          side: "enemy",
          damage_vulnerabilities: ["slashing"]
        )

      w =
        World.new()
        |> then_apply(World.add_character(f))
        |> then_apply(World.add_character(skel))

      # d20=10 → 15 vs CA 12 hit; d8=4 + str 3 = 7 slashing → 14
      assert {:ok, _msg, change} =
               Actions.attack(w, "Thane", "skeleton", "longsword", seq([10, 4]))

      {:ok, w2} = change.(w)
      assert w2.characters["skeleton"].hp == 30 - 14
    end

    test "bludgeoning vs SRD skeleton doubles; poison is immune" do
      wiz = Archetypes.wizard()
      skel = %{Monsters.skeleton(name: "skeleton") | hp: 30, max_hp: 30, ac: 12}

      w =
        World.new()
        |> then_apply(World.add_character(wiz))
        |> then_apply(World.add_character(skel))

      # quarterstaff: str 8 (−1) + prof 2 = +1. d20=15 → 16 vs CA 12 hit; d6=4 −1 = 3 → 6
      assert {:ok, _msg, change} =
               Actions.attack(w, "Lyra", "skeleton", "quarterstaff", seq([15, 4]))

      {:ok, w2} = change.(w)
      assert w2.characters["skeleton"].hp == 30 - 6

      w3 = then_apply(w2, World.apply_damage("skeleton", 10, "poison"))
      assert w3.characters["skeleton"].hp == 24
    end

    test "firebolt vs tiefling hellish_resistance is halved" do
      wiz = Archetypes.wizard()

      tiefling =
        Character.new(
          name: "Lilith",
          race: "tiefling",
          class: "warlock",
          hp: 20,
          max_hp: 20,
          ac: 12,
          side: "enemy",
          racial_traits: ["hellish_resistance"]
        )

      w =
        World.new()
        |> then_apply(World.add_character(wiz))
        |> then_apply(World.add_character(tiefling))

      # firebolt: +5, d20=10 → 15 vs CA 12 hit; d10=6 fire → 3
      assert {:ok, _msg, change} = Actions.spell(w, "Lyra", "firebolt", "Lilith", seq([10, 6]))
      {:ok, w2} = change.(w)
      assert w2.characters["Lilith"].hp == 20 - 3
    end
  end

  # helpers ----------------------------------------------------------------
  defp then_apply(world, change_fn) do
    assert {:ok, w} = change_fn.(world)
    w
  end

  defp then_change({:ok, _msg, change}), do: change
end
