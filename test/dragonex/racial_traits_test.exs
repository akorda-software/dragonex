defmodule Dragonex.RacialTraitsTest do
  @moduledoc """
  Rasgos raciales automáticos (D1): el agente no llama nada — el motor
  los aplica leyendo `Character.race` (el builder ya la fija, D52).

  * **D66 Lucky (mediano, M50)**: en las tres tiradas de d20 con
    personaje (`Combat.attack_roll`, `Combat.saving_throw`,
    `Combat.ability_check`), si el d20 EFECTIVO (el conservado tras
    ventaja/desventaja) es 1 → se rerollea UNA vez y se USA el nuevo
    resultado (RAW "must use the new roll"; no es keep-best). El reroll
    pasa por el mismo roller (el RollLog lo registra) y el desglose lo
    muestra con la etiqueta "(Lucky: 1→N)". Death saves no aplican (no
    hay personaje en esa ruta).
  * **D67 Resistencia implacable (semi-orco, M51)**: en
    `World.apply_damage/3`, tras el auto-revert de Wild Shape (D63), hp
    final ≤ 0 → 1 pg una vez por descanso largo
    (`relentless_endurance_used`); `long_rest` recarga, `short_rest` no.
  * **Fix D64**: `start_uncanny_dodge` entra en los narrated tool calls
    de `Text.scrub` (D7).
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Rules.Combat, Text, Weapon, World}

  defp fixed(n), do: Dragonex.Dice.always(n)

  # A roller that pops values from a queue, so the reroll (and the two
  # dice of advantage) are distinct and countable.
  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp consumed?, do: Process.get(:seq) == []

  defp halfling(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Pippo",
          race: "halfling",
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
          side: "pc",
          weapons: [
            %Weapon{
              name: "shortsword",
              dice: "1d6",
              damage_type: "piercing",
              attack_ability: :str
            }
          ]
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
            %Weapon{name: "greataxe", dice: "1d12", damage_type: "slashing", attack_ability: :str}
          ]
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

  # ------------------------------------------------------------- D66 Lucky

  describe "Lucky (D66) — Combat.attack_roll" do
    test "d20 1 se rerollea una vez y se USA el nuevo resultado" do
      h = halfling()

      # 1 (reroll Lucky) → 7; total 7 + prof 2 + FUE 2 = 11 vs CA 11 → hit.
      assert {:hit, 7, 11} = Combat.attack_roll(h, weapon_of(h, "shortsword"), 11, seq([1, 7]))
      assert consumed?()
    end

    test "reroll nat 1 otra vez se queda en 1 (sólo un reroll)" do
      h = halfling()

      assert {:miss, 1, 5} = Combat.attack_roll(h, weapon_of(h, "shortsword"), 20, seq([1, 1]))
      assert consumed?()
    end

    test "reroll a 20 es crítico (el nuevo dado manda)" do
      h = halfling()

      assert {:crit, 20, _total} =
               Combat.attack_roll(h, weapon_of(h, "shortsword"), 25, seq([1, 20]))

      assert consumed?()
    end

    test "no-mediano NO rerollea" do
      human = halfling(race: "human")

      assert {:miss, 1, _} =
               Combat.attack_roll(human, weapon_of(human, "shortsword"), 5, seq([1]))

      assert consumed?()
    end

    test "ventaja: sólo rerollea si el dado CONSERVADO es 1" do
      h = halfling()

      # max(1, 20) = 20 → no Lucky: el 1 descartado no rerrollea.
      assert {:crit, 20, _} =
               Combat.attack_roll(h, weapon_of(h, "shortsword"), 25, seq([1, 20]), :advantage)

      assert consumed?()

      # max(1, 1) = 1 → Lucky una vez → 9.
      assert {:hit, 9, 13} =
               Combat.attack_roll(h, weapon_of(h, "shortsword"), 13, seq([1, 1, 9]), :advantage)

      assert consumed?()
    end

    test "desventaja: el 1 conservado rerrollea" do
      h = halfling()

      # min(15, 1) = 1 → Lucky → 8; total 8 + 2 + 2 = 12.
      assert {:hit, 8, 12} =
               Combat.attack_roll(
                 h,
                 weapon_of(h, "shortsword"),
                 12,
                 seq([15, 1, 8]),
                 :disadvantage
               )

      assert consumed?()
    end

    test "attack_roll_tagged devuelve la etiqueta; attack_roll la dropea" do
      h = halfling()

      assert {:hit, 7, 11, "(Lucky: 1→7)"} =
               Combat.attack_roll_tagged(h, weapon_of(h, "shortsword"), 11, seq([1, 7]))

      assert {:hit, 7, 11, nil} =
               Combat.attack_roll_tagged(h, weapon_of(h, "shortsword"), 11, seq([7]))
    end
  end

  describe "Lucky (D66) — Combat.saving_throw" do
    test "d20 1 rerrollea y usa el nuevo (salvación)" do
      h = halfling()

      # DES +1 → 15 + 1 = 16 vs CD 12.
      assert {15, 16, true, "(Lucky: 1→15)"} =
               Combat.saving_throw_tagged(h, :dex, 12, seq([1, 15]))

      assert consumed?()
    end

    test "salvación sin 1 no rerrollea" do
      h = halfling()
      assert {5, 6, false, nil} = Combat.saving_throw_tagged(h, :dex, 12, seq([5]))
      assert consumed?()
    end

    test "death saves no aplican (sin personaje en la ruta)" do
      # death_save/2 no recibe Character: nat 1 sigue siendo doble fallo.
      assert {:crit_fail, 1, 2, 0} = Combat.death_save(fixed(1))
    end
  end

  describe "Lucky (D66) — Combat.ability_check" do
    test "d20 1 rerrollea y usa el nuevo (chequeo)" do
      h = halfling()

      # FUE +2 → 9 + 2 = 11 vs CD 10.
      assert {9, 11, true, "(Lucky: 1→9)"} = Combat.ability_check_tagged(h, :str, 10, seq([1, 9]))
      assert consumed?()
    end

    test "no-mediano no rerrollea en chequeos" do
      human = halfling(race: "human")
      assert {1, 3, true} = Combat.ability_check(human, :str, 3, seq([1]))
      assert consumed?()
    end
  end

  describe "Lucky (D66) — mensajes" do
    test "make_attack: el desglose muestra el reroll" do
      w = world([halfling(), goblin()])

      # d20 1 → Lucky 17 (17+2+2=21 vs CA 13 hit); daño 1d6(4)+2=6.
      assert {:ok, msg, _change} =
               Actions.attack(w, "Pippo", "Goblin", "shortsword", seq([1, 17, 4]))

      assert msg =~ "(Lucky: 1→17)"
      assert msg =~ "d20 17 (Lucky: 1→17): 21 vs CA 13"
    end

    test "ability_check: el desglose muestra el reroll" do
      w = world([halfling()])

      assert {:ok, msg, _change} = Actions.check(w, "Pippo", "str", 10, false, seq([1, 15]))
      assert msg =~ "(Lucky: 1→15)"
      assert msg =~ "d20 15 (Lucky: 1→15)"
    end

    test "skill check (stealth de un mediano pícaro) también lo muestra" do
      rogue = halfling(name: "Mia", class: "rogue", dex: 16, str: 10, level: 2)
      w = world([rogue, goblin()])

      assert {:ok, msg, _change} =
               Actions.cunning_action_hide(w, "Mia", seq([1, 20]))

      assert msg =~ "(Lucky: 1→20)"
    end
  end

  # ------------------------------------------- D67 Resistencia implacable

  describe "Relentless Endurance (D67) — World.apply_damage" do
    test "semi-orco a 0 → queda a 1 y marca la flag (con nota en el log)" do
      w = world([half_orc()])

      {:ok, w2} = World.apply_damage("Grok", 20).(w)
      s = w2.characters["Grok"]
      assert s.hp == 1
      assert s.relentless_endurance_used == true
      assert {_, note} = hd(w2.log)
      assert note =~ "la furia semi-orca mantiene a Grok en pie con 1 pg"
      assert note =~ "(Resistencia implacable)"
    end

    test "daño que no llega a 0 no gasta la flag" do
      w = world([half_orc()])

      {:ok, w2} = World.apply_damage("Grok", 5).(w)
      assert w2.characters["Grok"].hp == 9
      assert w2.characters["Grok"].relentless_endurance_used == false
    end

    test "segundo golpe a 0 con la flag gastada → queda a 0" do
      w = world([half_orc()])

      {:ok, w} = World.apply_damage("Grok", 20).(w)
      {:ok, w2} = World.apply_damage("Grok", 5).(w)

      assert w2.characters["Grok"].hp == 0
      assert w2.characters["Grok"].relentless_endurance_used == true
    end

    test "no semi-orco → 0 con normalidad" do
      w = world([half_orc(name: "Thane", race: "human")])

      {:ok, w2} = World.apply_damage("Thane", 20).(w)
      assert w2.characters["Thane"].hp == 0
      assert w2.characters["Thane"].relentless_endurance_used == false
    end

    test "temp_hp absorbe antes y la flag sólo salta si aún cae a 0" do
      w = world([half_orc()])
      {:ok, w} = World.apply_temp_hp("Grok", 5).(w)

      # 5 de temp absorben el 6 → queda a 14/14… no: 6-5=1 → PG 13, sin RE.
      {:ok, w2} = World.apply_damage("Grok", 6).(w)
      assert w2.characters["Grok"].hp == 13
      assert w2.characters["Grok"].relentless_endurance_used == false
    end
  end

  describe "Relentless Endurance (D67) — descansos" do
    test "long rest recarga la flag" do
      w = world([half_orc()])
      {:ok, w} = World.apply_damage("Grok", 20).(w)
      assert w.characters["Grok"].relentless_endurance_used == true

      assert {:ok, _, change} = Actions.long_rest(w, "Grok")
      {:ok, w2} = change.(w)
      assert w2.characters["Grok"].relentless_endurance_used == false
      assert w2.characters["Grok"].hp == 14
    end

    test "short rest NO recarga la flag" do
      w = world([half_orc()])
      {:ok, w} = World.apply_damage("Grok", 20).(w)

      assert {:ok, _, change} = Actions.short_rest(w, "Grok", fixed(4))
      {:ok, w2} = change.(w)
      assert w2.characters["Grok"].relentless_endurance_used == true
    end

    test "tras recargar, vuelve a salvar" do
      w = world([half_orc()])
      {:ok, w} = World.apply_damage("Grok", 20).(w)
      assert {:ok, _, change} = Actions.long_rest(w, "Grok")
      {:ok, w} = change.(w)

      {:ok, w2} = World.apply_damage("Grok", 99).(w)
      assert w2.characters["Grok"].hp == 1
      assert w2.characters["Grok"].relentless_endurance_used == true
    end
  end

  describe "Relentless Endurance (D67) — interacciones" do
    test "wild shape: druida semi-orco, exceso que lo dejaría a 0 → RE lo salva a 1" do
      druid =
        half_orc(
          name: "Morg",
          class: "druid",
          level: 2,
          hp: 10,
          max_hp: 10,
          wild_shape_uses: 2
        )

      w = world([druid])

      # Lobo del catálogo (11 pg); daño 25 → bestia cae, exceso 14 ≥ 10
      # originales → PG final 0 → RE lo mantiene en 1 (ya en forma propia).
      assert {:ok, _, change} = Actions.wild_shape(w, "Morg", "wolf")
      {:ok, w} = change.(w)
      assert w.characters["Morg"].hp == 11

      {:ok, w2} = World.apply_damage("Morg", 25).(w)
      s = w2.characters["Morg"]
      assert s.hp == 1
      assert s.wild_shape == nil
      assert s.relentless_endurance_used == true
      assert elem(hd(w2.log), 1) =~ "Resistencia implacable"
    end

    test "uncanny dodge mitiga ANTES; si aún cae a 0, RE aplica" do
      rogue =
        half_orc(
          name: "Vex",
          class: "rogue",
          level: 5,
          hp: 12,
          max_hp: 12,
          uncanny_dodge: true
        )

      w = world([rogue])

      # Daño 30 → dodge 15 → 0 pg → RE salva a 1. Ambas consumidas.
      {:ok, w2} = World.apply_damage("Vex", 30).(w)
      s = w2.characters["Vex"]
      assert s.hp == 1
      assert s.uncanny_dodge == false
      assert s.relentless_endurance_used == true
    end

    test "uncanny dodge que evita el 0 no gasta RE" do
      rogue =
        half_orc(
          name: "Vex",
          class: "rogue",
          level: 5,
          hp: 12,
          max_hp: 12,
          uncanny_dodge: true
        )

      w = world([rogue])

      # Daño 20 → dodge 10 → PG 2 → sin RE.
      {:ok, w2} = World.apply_damage("Vex", 20).(w)
      s = w2.characters["Vex"]
      assert s.hp == 2
      assert s.uncanny_dodge == false
      assert s.relentless_endurance_used == false
    end
  end

  describe "Relentless Endurance (D67) — Character/Codec" do
    test "default false en Character.new y changeset" do
      assert Character.new(name: "X", class: "barbarian").relentless_endurance_used == false

      {:ok, sheet} =
        Character.new(name: "X", class: "barbarian")
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.apply_action(:insert)

      assert sheet.relentless_endurance_used == false
    end

    test "ida y vuelta Codec conserva la flag" do
      w = world([half_orc()])
      {:ok, w} = World.apply_damage("Grok", 20).(w)

      decoded = Codec.decode(Codec.encode(w))
      assert decoded.characters["Grok"].relentless_endurance_used == true
    end

    test "jsonb viejo sin campo → false" do
      encoded = half_orc() |> Codec.encode_character() |> Map.drop(["relentless_endurance_used"])

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.relentless_endurance_used == false
    end
  end

  # ------------------------------------------------- Fix D64 (Text.scrub)

  describe "Text.scrub — start_uncanny_dodge narrado (fix D64)" do
    test "se elimina del texto scrubbeado" do
      text = ~s{Lyra: start_uncanny_dodge("Lyra") y se prepara para esquivar.}

      scrubbed = Text.scrub(text)
      refute scrubbed =~ "start_uncanny_dodge"
      assert scrubbed =~ "se prepara para esquivar"
    end
  end
end
