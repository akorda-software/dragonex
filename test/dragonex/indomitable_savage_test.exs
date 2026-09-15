defmodule Dragonex.IndomitableSavageTest do
  @moduledoc """
  D68 Indomitable (guerrero L9+) y D69 Savage Attacks (semi-orco) — ambos
  automáticos (D1): el agente no llama nada, el motor los aplica.

  * **D68 (M52)**: en TODOS los sitios de `Actions` donde el personaje
    salva (hechizo :save, turn_undead SAB, concentración CON), un fallo de
    un guerrero L9+ con `indomitable_used == false` → UN reroll (misma
    llamada: mismo modo/bonus; Lucky D66 puede dispararse gratis en el
    reroll) y se USA el nuevo resultado (RAW). Marca `indomitable_used` y
    etiqueta "(Indomitable: X→Y)" en el desglose. 1 uso por descanso largo
    (`long_rest` recarga, `short_rest` no). Death saves y auto-fails fuera
    (no hay dado que rerrollear).
  * **D69 (M53)**: en `Combat.damage_roll` (crítico de ARMA melee), un
    semi-orco añade UN dado del tamaño del arma (no doblado, no la
    expresión completa). Hechizos y armas a distancia no aplican.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Rules.Combat, Spell, Weapon, World}

  defp fixed(n), do: Dragonex.Dice.always(n)

  # A roller that pops values from a queue, so the Indomitable reroll (and
  # each damage die) is distinct and countable.
  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp consumed?, do: Process.get(:seq) == []

  # Wizard L1: int 16 → acid splash (salvación DES) CD 13 (8 + prof 2 + mod 3).
  defp mage(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "mage",
          class: "wizard",
          race: "human",
          level: 1,
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
            }
          ]
        ],
        opts
      )
    )
  end

  # Guerrero L9: DES 12 (+1) → CD 13. `indomitable_used` false por defecto.
  defp fighter9(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Bjorn",
          race: "human",
          class: "fighter",
          level: 9,
          hp: 40,
          max_hp: 40,
          ac: 16,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          side: "enemy",
          weapons: [
            %Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
          ]
        ],
        opts
      )
    )
  end

  defp cleric(opts \\ []) do
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
          cha: 10,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp half_orc(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Grok",
          race: "half-orc",
          class: "barbarian",
          level: 1,
          hp: 14,
          max_hp: 14,
          ac: 13,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc",
          weapons: [
            %Weapon{
              name: "greataxe",
              dice: "1d12",
              damage_type: "slashing",
              attack_ability: :str
            },
            %Weapon{
              name: "maul",
              dice: "2d6",
              damage_type: "bludgeoning",
              attack_ability: :str
            },
            %Weapon{
              name: "longbow",
              dice: "1d8",
              damage_type: "piercing",
              attack_ability: :dex,
              ranged: true
            }
          ]
        ],
        opts
      )
    )
  end

  defp ally(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Krug",
          race: "human",
          class: "fighter",
          level: 1,
          hp: 12,
          max_hp: 12,
          ac: 14,
          str: 14,
          dex: 12,
          con: 12,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp goblin do
    Character.new(
      name: "Goblin",
      class: "monster",
      race: "goblinoid",
      level: 1,
      hp: 7,
      max_hp: 7,
      ac: 13,
      dex: 14,
      side: "enemy",
      weapons: [
        %Weapon{
          name: "scimitar",
          dice: "1d6",
          damage_type: "slashing",
          attack_ability: :dex,
          finesse: true
        }
      ]
    )
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  defp weapon_of(c, name), do: Enum.find(c.weapons, &(&1.name == name))

  # ---------------------------------------------- D68 Indomitable (hechizo)

  describe "Indomitable (D68) — salvación de hechizo" do
    test "guerrero L9 falla → reroll, se usa el nuevo y el éxito evita daño" do
      w = world([mage(), fighter9()])

      # save 5+1=6 falla → reroll 18+1=19 ≥ CD 13; daño 1d6(4) → mitad 2.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 18, 4]))

      assert msg =~
               "Bjorn supera la salvación (d20 18 (Indomitable: 6→19): 19 vs CD 13), mitad de daño"

      assert msg =~ "2 de daño acid"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].hp == 38
      assert w2.characters["Bjorn"].indomitable_used == true
    end

    test "reroll que vuelve a fallar se queda (sólo un reroll)" do
      w = world([mage(), fighter9()])

      # save 6 falla → reroll 8 falla → daño completo 4.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 7, 4]))

      assert msg =~ "falla la salvación (d20 7 (Indomitable: 6→8): 8 vs CD 13)"
      assert msg =~ "4 de daño acid"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].hp == 36
      assert w2.characters["Bjorn"].indomitable_used == true
    end

    test "L8 no aplica" do
      w = world([mage(), fighter9(level: 8)])

      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 4]))

      refute msg =~ "Indomitable"

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].hp == 36
      assert w2.characters["Bjorn"].indomitable_used == false
      assert consumed?()
    end

    test "ya usado no aplica" do
      w = world([mage(), fighter9(indomitable_used: true)])

      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 4]))

      refute msg =~ "Indomitable"

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].hp == 36
      assert w2.characters["Bjorn"].indomitable_used == true
      assert consumed?()
    end

    test "no guerrero no aplica" do
      w = world([mage(), fighter9(class: "cleric")])

      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 4]))

      refute msg =~ "Indomitable"

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].indomitable_used == false
    end

    test "long rest recarga y vuelve a rerrollear" do
      w = world([mage(), fighter9()])

      assert {:ok, _, change} = Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 18, 4]))
      {:ok, w} = change.(w)
      assert w.characters["Bjorn"].indomitable_used == true

      assert {:ok, _, rest} = Actions.long_rest(w, "Bjorn")
      {:ok, w2} = rest.(w)
      assert w2.characters["Bjorn"].indomitable_used == false
      assert w2.characters["Bjorn"].hp == 40

      assert {:ok, msg, _change} =
               Actions.spell(w2, "mage", "acid splash", "Bjorn", seq([5, 18, 4]))

      assert msg =~ "Indomitable"
    end

    test "short rest NO recarga" do
      w = world([mage(), fighter9()])

      assert {:ok, _, change} = Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 18, 4]))
      {:ok, w} = change.(w)

      assert {:ok, _, rest} = Actions.short_rest(w, "Bjorn", fixed(4))
      {:ok, w2} = rest.(w)
      assert w2.characters["Bjorn"].indomitable_used == true
    end

    test "Lucky (D66) puede dispararse gratis en el reroll" do
      w = world([mage(), fighter9(race: "halfling")])

      # save 5→6 falla → reroll 1 → Lucky → 18: total 19 ≥ 13; daño 4 → 2.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 1, 18, 4]))

      assert msg =~ "d20 18 (Indomitable: 6→19) (Lucky: 1→18): 19 vs CD 13"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].indomitable_used == true
    end

    test "Heightened (D65): el reroll conserva la desventaja" do
      w = world([mage(metamagic: %{option: "heightened", target: "Bjorn"}), fighter9()])

      # desventaja min(3,2)=2 → 3 falla → reroll desventaja min(15,14)=14 →
      # 15 ≥ 13; daño 4 → mitad 2.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([3, 2, 15, 14, 4]))

      assert msg =~
               "(d20 14 (Indomitable: 3→15): 15 vs CD 13) (desventaja) (Metamagia: Heightened)"

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].indomitable_used == true
    end

    # ADR D68: "el aura D61 (bonus plano) sí se re-suma" al reroll.
    test "Aura de Protección (D61): el reroll vuelve a sumar el bonus del paladín" do
      paladin =
        Character.new(
          name: "Kara",
          class: "paladin",
          level: 6,
          hp: 30,
          max_hp: 30,
          ac: 18,
          str: 16,
          dex: 10,
          con: 14,
          cha: 16,
          side: "enemy"
        )

      w = world([mage(), fighter9(), paladin])

      # Primer intento 5+1+3(aura)=9 < CD 13 → fallo; reroll 9+1+3(aura
      # re-sumada)=13 ≥ 13 → éxito SIN el aura habría vuelto a fallar.
      assert {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "Bjorn", seq([5, 9, 4]))

      assert msg =~ "(d20 9 (Indomitable: 9→13): 13 vs CD 13 +3 aura)"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].indomitable_used == true
      assert w2.characters["Bjorn"].hp == 40 - 2
    end
  end

  # ------------------------------------------- D68 Indomitable (turn_undead)

  describe "Indomitable (D68) — turn_undead" do
    test "no-muerto guerrero L9 rerrollea la SAB y la supera" do
      w = world([cleric(), fighter9(name: "Caballero", race: "undead")])

      # SAB 2+0=2 falla vs CD 13 → reroll 15 supera.
      assert {:ok, msg, change} = Actions.turn_undead(w, "Aldric", seq([2, 15]))

      assert msg ==
               "Aldric usa Expulsar no-muertos (CD 13): Caballero (Indomitable: 2→15) supera la salvación (usos restantes 0)."

      assert consumed?()

      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Caballero", "frightened")
      assert w2.characters["Caballero"].indomitable_used == true
      assert w2.characters["Aldric"].channel_divinity_used == true
    end

    test "reroll fallido → asustado igualmente (y gasta el uso)" do
      w = world([cleric(), fighter9(name: "Caballero", race: "undead")])

      assert {:ok, msg, change} = Actions.turn_undead(w, "Aldric", seq([2, 5]))

      assert msg ==
               "Aldric usa Expulsar no-muertos (CD 13): Caballero (Indomitable: 2→5) queda asustado (usos restantes 0)."

      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Caballero", "frightened")
      assert w2.characters["Caballero"].indomitable_used == true
    end
  end

  # ----------------------------------------- D68 Indomitable (concentración)

  describe "Indomitable (D68) — concentración" do
    test "reroll del CON save mantiene la concentración" do
      w = world([mage(), fighter9(concentrating: "bless")])

      # save hechizo 20+1=21 supera (sin reroll); daño 4 → mitad 2; CON save
      # 3+2=5 < CD 10 falla → reroll 17+2=19 mantiene.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([20, 4, 3, 17]))

      assert msg =~
               "Bjorn mantiene la concentración en bless (d20 17 (Indomitable: 5→19): 19 vs CD 10)"

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].concentrating == "bless"
      assert w2.characters["Bjorn"].indomitable_used == true
      assert w2.characters["Bjorn"].hp == 38
    end

    test "con la flag gastada la concentración se pierde (un solo uso)" do
      w = world([mage(), fighter9(concentrating: "bless", indomitable_used: true)])

      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "acid splash", "Bjorn", seq([20, 4, 3]))

      assert msg =~ "Bjorn pierde la concentración en bless"
      refute msg =~ "Indomitable"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bjorn"].concentrating == nil
      assert w2.characters["Bjorn"].indomitable_used == true
    end
  end

  # --------------------------------------- D68 Indomitable (Character/Codec)

  describe "Indomitable (D68) — Character/Codec" do
    test "default false en Character.new y changeset" do
      assert Character.new(name: "X", class: "fighter", level: 9).indomitable_used == false

      {:ok, sheet} =
        Character.new(name: "X", class: "fighter", level: 9)
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.apply_action(:insert)

      assert sheet.indomitable_used == false
    end

    test "ida y vuelta Codec conserva la flag" do
      w = world([fighter9(indomitable_used: true)])
      assert Codec.decode(Codec.encode(w)).characters["Bjorn"].indomitable_used == true
    end

    test "jsonb viejo sin campo → false" do
      encoded = fighter9() |> Codec.encode_character() |> Map.drop(["indomitable_used"])

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.indomitable_used == false
    end
  end

  # ----------------------------------- D69 Savage Attacks (Combat.damage_roll)

  describe "Savage Attacks (D69) — Combat.damage_roll" do
    test "semi-orco crit melee: UN dado del arma extra" do
      g = half_orc()

      # crit 2×1d12(6)=12 + savage 1d12(6) + FUE 3 = 21.
      assert {21, 6} = Combat.damage_roll_tagged(g, weapon_of(g, "greataxe"), :crit, fixed(6))
      assert Combat.damage_roll(g, weapon_of(g, "greataxe"), :crit, fixed(6)) == 21
    end

    test "hit normal: sin dado extra" do
      g = half_orc()
      assert {9, 0} = Combat.damage_roll_tagged(g, weapon_of(g, "greataxe"), :hit, fixed(6))
    end

    test "arma 2d6: savage añade UN dado, no la expresión completa" do
      g = half_orc()

      # crit 4×d6(3)=12 + savage 1×d6(3) + FUE 3 = 18.
      assert {18, 3} = Combat.damage_roll_tagged(g, weapon_of(g, "maul"), :crit, fixed(3))
    end

    test "crit a distancia NO" do
      g = half_orc()

      # crit 2×1d8(4)=8 + DES 1 = 9, sin savage.
      assert {9, 0} = Combat.damage_roll_tagged(g, weapon_of(g, "longbow"), :crit, fixed(4))
    end

    test "no semi-orco NO" do
      f = fighter9(side: "pc")

      # crit 2×1d8(5)=10 + FUE 3 = 13, sin savage.
      assert {13, 0} = Combat.damage_roll_tagged(f, weapon_of(f, "longsword"), :crit, fixed(5))
    end
  end

  # -------------------------------------- D69 Savage Attacks (Actions.attack)

  describe "Savage Attacks (D69) — Actions.attack" do
    test "crit melee suma el dado extra y lo muestra en el desglose" do
      w = world([half_orc(), goblin()])

      # d20 20 crit (25 vs CA 13); daño 2×1d12(6)+savage 6+FUE 3 = 21.
      assert {:ok, msg, change} =
               Actions.attack(w, "Grok", "Goblin", "greataxe", seq([20, 6, 6, 6]))

      assert msg =~
               "Grok CRÍTICO a Goblin (d20 20: 25 vs CA 13) por 21 de daño slashing (+6 Savage)."

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 0
    end

    test "crit a distancia NO aplica" do
      w = world([half_orc(), goblin()])

      assert {:ok, msg, _change} =
               Actions.attack(w, "Grok", "Goblin", "longbow", seq([20, 4, 4]))

      assert msg =~ "por 9 de daño piercing"
      refute msg =~ "Savage"
    end

    test "hechizo crit NO aplica (sólo daño de arma)" do
      gruk =
        half_orc(
          name: "Gruk",
          class: "wizard",
          level: 1,
          str: 10,
          dex: 12,
          int: 16,
          weapons: [],
          spells: [
            %Spell{
              name: "fire bolt",
              level: 0,
              kind: :attack,
              casting_ability: :int,
              dice: "1d10",
              damage_type: "fire"
            }
          ]
        )

      w = world([gruk, goblin()])

      # d20 20 crit; daño 2×1d10(5) = 10 — sin dado savage.
      assert {:ok, msg, _change} =
               Actions.spell(w, "Gruk", "fire bolt", "Goblin", seq([20, 5, 5]))

      assert msg =~ "por 10 de daño fire"
      refute msg =~ "Savage"
    end

    test "no semi-orco NO aplica" do
      w = world([fighter9(side: "pc"), goblin()])

      assert {:ok, msg, _change} =
               Actions.attack(w, "Bjorn", "Goblin", "longsword", seq([20, 5, 5]))

      assert msg =~ "por 13 de daño slashing"
      refute msg =~ "Savage"
    end

    test "apila con sneak (pícaro semi-orco: ambos dados en crit)" do
      vex =
        half_orc(
          name: "Vex",
          class: "rogue",
          level: 5,
          str: 10,
          dex: 16,
          weapons: [
            %Weapon{
              name: "shortsword",
              dice: "1d6",
              damage_type: "piercing",
              attack_ability: :dex,
              finesse: true
            }
          ]
        )

      w = world([vex, ally(), goblin()])

      # d20 20 crit; arma 2×d6(3)+savage 3+DES 3 = 12; sneak crit 6×d6(3)=18.
      assert {:ok, msg, _change} =
               Actions.attack(
                 w,
                 "Vex",
                 "Goblin",
                 "shortsword",
                 seq([20, 3, 3, 3, 3, 3, 3, 3, 3, 3])
               )

      assert msg =~
               "Vex CRÍTICO a Goblin (d20 20: 26 vs CA 13) por 30 de daño piercing (+3 Savage) (+18 sneak)."

      assert consumed?()
    end
  end
end
