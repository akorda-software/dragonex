defmodule Dragonex.PaladinAurasTest do
  @moduledoc """
  Auras de paladín 5e: Aura of Protection (D61 / M45) y Aura of Courage
  (D62 / M46). Pasivas del motor — sin tools. Simplificación sin grid: el
  aura cubre a TODO el mismo `side` con el paladín consciente (hp > 0).

  D61 (L6+): el modificador de CHA del paladín se suma a TODAS las
  salvaciones de su side (spells, turn_undead, death saves, concentración);
  varios paladines apilan; CHA < 10 da bonus negativo sin piso (RAW).

  D62 (L10+): el aliado de side de un paladín L10+ consciente (él incluido)
  no puede quedar frightened — `apply_condition` no muta y el mensaje lo
  dice; la regla es genérica por side (un no-muerto aliado también es
  inmune, documentado).
  """
  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Rules.Combat, Spell, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end

  defp paladin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Rhogar",
          class: "paladin",
          race: "human",
          level: 6,
          hp: 20,
          max_hp: 20,
          ac: 18,
          str: 16,
          dex: 10,
          con: 14,
          cha: 16,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp paladin2(opts), do: paladin(Keyword.merge([name: "Seraphine"], opts))

  defp ally(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          race: "human",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 16,
          str: 14,
          dex: 10,
          con: 10,
          wis: 10,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp cleric(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Aldric",
          class: "cleric",
          race: "human",
          level: 2,
          hp: 16,
          max_hp: 16,
          ac: 16,
          str: 14,
          dex: 10,
          con: 14,
          wis: 16,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp undead(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Zombi",
          class: "monster",
          race: "undead",
          level: 1,
          hp: 12,
          max_hp: 12,
          ac: 8,
          wis: 10,
          side: "enemy"
        ],
        opts
      )
    )
  end

  # Enemy wizard with a DEX-save cantrip: int 16 → save DC 13.
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
      side: "enemy",
      spells: [
        %Spell{
          name: "acid splash",
          level: 0,
          kind: :save,
          casting_ability: :int,
          save_ability: :dex,
          dice: "1d6",
          damage_type: "acid"
        }
      ]
    )
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      add(w, World.add_character(c))
    end)
  end

  # ----------------------------------------------------------------- D61 tests

  describe "Aura of Protection (D61) — spell saves" do
    test "aliado de paladín L6 CHA 16: +3 al total y en el mensaje" do
      w = world([mage(), ally([]), paladin([])])

      # Save 10 + 0 (DES) = 10 vs CD 13; aura +3 → 13 → éxito (sin aura falla).
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(10))

      assert msg =~ "supera la salvación (d20 10: 13 vs CD 13 +3 aura)"
      {:ok, w2} = change.(w)
      # Daño 1d6 con roller fijo 10 → mitad 5 en éxito.
      assert w2.characters["Thane"].hp == 20 - 5
    end

    test "sin paladín → igual que antes (10 vs 13 falla, daño completo)" do
      w = world([mage(), ally([])])

      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(10))

      assert msg =~ "falla la salvación (d20 10: 10 vs CD 13)"
      refute msg =~ "aura"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 20 - 10
    end

    test "paladín caído (hp 0) → sin bonus" do
      w = world([mage(), ally([]), paladin(hp: 0)])

      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(10))

      assert msg =~ "falla la salvación (d20 10: 10 vs CD 13)"
      refute msg =~ "aura"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 20 - 10
    end

    test "paladín L5 → sin bonus" do
      w = world([mage(), ally([]), paladin(level: 5)])

      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(10))

      assert msg =~ "falla la salvación (d20 10: 10 vs CD 13)"
      refute msg =~ "aura"
    end

    test "el propio paladín se beneficia de su aura" do
      w = world([mage(), paladin([])])

      # Rhogar DES 10: 10 + 3 (aura propia) = 13 → éxito.
      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Rhogar", fixed(10))

      assert msg =~ "supera la salvación (d20 10: 13 vs CD 13 +3 aura)"
    end

    test "dos paladines L6 apilan (+3 y +2 → +5)" do
      w = world([mage(), ally([]), paladin([]), paladin2(cha: 14)])

      # 8 + 5 = 13 vs 13 → éxito (sin auras falla).
      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(8))

      assert msg =~ "supera la salvación (d20 8: 13 vs CD 13 +5 aura)"
    end

    test "CHA 8 → bonus negativo sin piso (-1)" do
      w = world([mage(), ally([]), paladin(cha: 8)])

      # 13 - 1 = 12 vs 13 → falla (sin aura superaba).
      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(13))

      assert msg =~ "falla la salvación (d20 13: 12 vs CD 13 -1 aura)"
    end

    test "el aura no alcanza al enemigo del paladín" do
      w = world([mage(), undead([]), paladin([])])

      # Zombi DES 10: 10 vs 13, sin aura (side enemy) → falla.
      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Zombi", fixed(10))

      assert msg =~ "falla la salvación (d20 10: 10 vs CD 13)"
      refute msg =~ "aura"
    end
  end

  describe "Aura of Protection (D61) — death saves" do
    test "el +3 convierte un 7 en éxito de salvación de muerte" do
      w = world([ally(hp: 0), paladin([])])

      {:ok, msg, change} = Actions.death_save(w, "Thane", fixed(7))

      assert msg =~ "saca 7 (+3 aura) — un éxito de salvación de muerte."
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].death_saves == %{successes: 1, fails: 0}
    end

    test "sin paladín un 7 es fallo (igual que antes)" do
      w = world([ally(hp: 0)])

      {:ok, msg, change} = Actions.death_save(w, "Thane", fixed(7))

      assert msg =~ "un fallo de salvación de muerte"
      refute msg =~ "aura"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].death_saves == %{successes: 0, fails: 1}
    end

    test "aura negativa (CHA 8) hunde un 10 en fallo" do
      w = world([ally(hp: 0), paladin(cha: 8)])

      {:ok, msg, change} = Actions.death_save(w, "Thane", fixed(10))

      assert msg =~ "saca 10 (-1 aura) — un fallo de salvación de muerte."
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].death_saves == %{successes: 0, fails: 1}
    end

    test "nat 20 revive y nat 1 son dos fallos con o sin aura" do
      assert Combat.death_save(fixed(20), 3) == {:revive, 20, 0, 0}
      assert Combat.death_save(fixed(1), 3) == {:crit_fail, 1, 2, 0}
      assert Combat.death_save(fixed(1), -1) == {:crit_fail, 1, 2, 0}
    end
  end

  describe "Aura of Protection (D61) — turn_undead (SAB)" do
    test "no-muerto aliado del paladín suma +3 a la salvación de Sabiduría" do
      # Turn Undead afecta a cualquier no-muerto vivo salvo el clérigo; un
      # zombi del mismo side que un paladín L6 recibe el aura (regla genérica
      # por side, D61).
      w = world([cleric([]), undead(side: "pc"), paladin([])])

      # SAB 10 + 3 = 13 vs CD 13 → supera (sin aura fallaba).
      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(10))

      assert msg =~ "Zombi supera la salvación"
      {:ok, w2} = change.(w)
      assert w2.characters["Aldric"].channel_divinity_used == true
      refute World.has_condition?(w2, "Zombi", "frightened")
    end

    test "sin paladín el mismo 10 falla" do
      w = world([cleric([]), undead(side: "pc")])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(10))

      assert msg =~ "Zombi queda asustado"
      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Zombi", "frightened")
    end
  end

  describe "Aura of Protection (D61) — concentración (CON)" do
    test "el +3 sostiene una concentración que habría roto" do
      w =
        world([
          mage(),
          ally(concentrating: "bless"),
          paladin([])
        ])

      # Save 7+3=10 < 13 → falla → daño completo 6; CD concentración
      # max(10, 3) = 10; CON 7 + 3 (aura) = 10 → mantiene.
      {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(7))

      assert msg =~ "Thane mantiene la concentración en bless (d20 7: 10 vs CD 10 +3 aura)"
    end

    test "sin paladín la misma tirada rompe la concentración" do
      w = world([mage(), ally(concentrating: "bless")])

      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "Thane", fixed(7))

      assert msg =~ "Thane pierde la concentración en bless (d20 7: 7 vs CD 10)"
      refute msg =~ "aura"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].concentrating == nil
    end
  end

  # ----------------------------------------------------------------- D62 tests

  describe "Aura of Courage (D62) — frightened nunca aterriza" do
    test "aliado de paladín L10: sin mutación y mensaje de inmunidad" do
      w = world([cleric([]), undead(side: "pc"), paladin(level: 10)])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      assert msg =~ "Zombi es inmune al miedo (Aura de Coraje)"
      {:ok, w2} = change.(w)
      assert w2.characters["Aldric"].channel_divinity_used == true
      refute World.has_condition?(w2, "Zombi", "frightened")
    end

    test "World.apply_condition no muta a un aliado inmune" do
      w = world([ally([]), paladin(level: 10)])

      {:ok, w2} = World.apply_condition("Thane", "frightened").(w)

      refute World.has_condition?(w2, "Thane", "frightened")
      assert w2 == w
    end

    test "el propio paladín L10 es inmune" do
      w = world([paladin(level: 10)])

      {:ok, w2} = World.apply_condition("Rhogar", "frightened").(w)

      refute World.has_condition?(w2, "Rhogar", "frightened")
    end

    test "paladín L9 → el aliado SÍ recibe frightened" do
      w = world([cleric([]), undead(side: "pc"), paladin(level: 9)])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      assert msg =~ "Zombi queda asustado"
      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Zombi", "frightened")
    end

    test "paladín caído → el aliado SÍ recibe frightened" do
      w = world([cleric([]), undead(side: "pc"), paladin(level: 10, hp: 0)])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      assert msg =~ "Zombi queda asustado"
      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Zombi", "frightened")
    end

    test "enemigo del paladín SÍ recibe frightened (el aura no alcanza)" do
      w = world([cleric([]), undead(side: "enemy"), paladin(level: 10)])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      assert msg =~ "Zombi queda asustado"
      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Zombi", "frightened")
    end

    test "la inmunidad no rompe la idempotencia de otras condiciones" do
      w = world([ally([]), paladin(level: 10)])

      {:ok, w2} = World.apply_condition("Thane", "prone").(w)
      {:ok, w3} = World.apply_condition("Thane", "prone").(w2)

      conditions = w3.characters["Thane"].conditions
      assert length(conditions) == 1

      # frightened sobre un inmune dos veces → sigue sin mutar.
      {:ok, w4} = World.apply_condition("Thane", "frightened").(w3)
      {:ok, w5} = World.apply_condition("Thane", "frightened").(w4)

      assert length(w5.characters["Thane"].conditions) == 1
      refute World.has_condition?(w5, "Thane", "frightened")
    end

    test "remove_condition sigue funcionando tras la inmunidad" do
      w = world([ally([]), paladin(level: 9)])

      {:ok, w2} = World.apply_condition("Thane", "frightened").(w)
      assert World.has_condition?(w2, "Thane", "frightened")

      {:ok, w3} = World.remove_condition("Thane", "frightened").(w2)
      refute World.has_condition?(w3, "Thane", "frightened")
    end
  end

  describe "Aura of Courage (D62) — Tools.apply_condition" do
    test "el DM ve el mensaje de inmunidad y no muta el estado" do
      game =
        start_session(
          world: World.new(characters: %{"Thane" => ally([]), "Rhogar" => paladin(level: 10)}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(1)}}
      assert {:ok, msg} = Tools.apply_condition(dm, "Thane", "frightened")
      assert msg == "Thane es inmune al miedo (Aura de Coraje)"
      refute World.has_condition?(Session.read_state(game), "Thane", "frightened")
    end

    test "condiciones no-frightened pasan igual que antes" do
      game =
        start_session(
          world: World.new(characters: %{"Thane" => ally([]), "Rhogar" => paladin(level: 10)}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(1)}}
      assert {:ok, msg} = Tools.apply_condition(dm, "Thane", "prone")
      assert msg == "Thane ahora está prone"
      assert World.has_condition?(Session.read_state(game), "Thane", "prone")
    end
  end
end
