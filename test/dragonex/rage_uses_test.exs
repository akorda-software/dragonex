defmodule Dragonex.RageUsesTest do
  @moduledoc """
  Usos de Furia por descanso largo + Furia implacable L11+ (D72 / M56).

  - `Character.rage_uses_used` se gasta al ENTRAR en furia
    (`World.start_rage/1`), `end_rage/1` NO lo devuelve (RAW) y sólo el
    descanso largo recarga; el máximo por nivel es
    `Progression.rage_count/1` (tabla 5e).
  - Furia implacable: bárbaro L11+ `raging == true` cuyo hp final cae a
    0 → salvación CON vs `10 + 5 × relentless_rage_successes` (aura de
    Protección D61 suma — RAW cubre TODAS las salvaciones); éxito → 1 pg
    y sube la CD del siguiente intento; fallo → cae y la Resistencia
    implacable racial (D67) puede salvarle después (semi-orco: capas).
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Heroes.Progression, World}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp barbarian(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Grok",
          race: "human",
          class: "barbarian",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 14,
          str: 16,
          dex: 14,
          con: 16,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc",
          saving_proficiencies: ["con"]
        ],
        opts
      )
    )
  end

  # L11: prof 4 + CON 3 → salvación de CON = d20 + 7.
  defp veteran(opts \\ []),
    do: barbarian(Keyword.merge([level: 11, hp: 10, max_hp: 20, raging: true], opts))

  defp goblin do
    Character.new(
      name: "goblin",
      class: "monster",
      hp: 30,
      max_hp: 30,
      ac: 12,
      str: 16,
      dex: 14,
      side: "enemy",
      weapons: [
        %Dragonex.Weapon{
          name: "greataxe",
          dice: "1d12",
          damage_type: "slashing",
          attack_ability: :str
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

  defp last_note(%World{} = w), do: w.log |> List.first() |> elem(1)

  describe "Progression.rage_count/1 (tabla 5e)" do
    test "L1–2 → 2; L3–5 → 3; L6–11 → 4; L12–16 → 5; L17+ → 6" do
      assert Progression.rage_count(1) == 2
      assert Progression.rage_count(2) == 2
      assert Progression.rage_count(3) == 3
      assert Progression.rage_count(5) == 3
      assert Progression.rage_count(6) == 4
      assert Progression.rage_count(11) == 4
      assert Progression.rage_count(12) == 5
      assert Progression.rage_count(16) == 5
      assert Progression.rage_count(17) == 6
      assert Progression.rage_count(20) == 6
    end
  end

  describe "usos de Furia (D72) — start_rage gasta" do
    test "L1 tiene 2 usos; la 3ª furía es error sin mutar" do
      w = world([barbarian()])
      {:ok, w} = World.start_rage("Grok").(w)
      assert w.characters["Grok"].rage_uses_used == 1
      {:ok, w} = World.end_rage("Grok").(w)
      {:ok, w} = World.start_rage("Grok").(w)
      assert w.characters["Grok"].rage_uses_used == 2
      {:ok, w} = World.end_rage("Grok").(w)
      assert w.characters["Grok"].rage_uses_used == 2

      assert {:error, msg} = World.start_rage("Grok").(w)
      assert msg =~ "no le quedan furias hoy (2/2 usadas)"
      # sin mutar: sigue sin furia y con los 2 usos gastados
      assert w.characters["Grok"].raging == false
      assert w.characters["Grok"].rage_uses_used == 2
    end

    test "usos por nivel: L3 → 3, L6 → 4, L12 → 5, L17 → 6" do
      for {level, count} <- [{3, 3}, {6, 4}, {12, 5}, {17, 6}] do
        w =
          Enum.reduce(1..count, world([barbarian(level: level)]), fn _, acc ->
            {:ok, acc} = World.start_rage("Grok").(acc)
            {:ok, acc} = World.end_rage("Grok").(acc)
            acc
          end)

        assert w.characters["Grok"].rage_uses_used == count
        assert {:error, msg} = World.start_rage("Grok").(w)
        assert msg =~ "(#{count}/#{count} usadas)"
        assert w.characters["Grok"].rage_uses_used == count
      end
    end

    test "end_rage NO devuelve el uso" do
      w = world([barbarian(raging: true, rage_uses_used: 1)])
      {:ok, w} = World.end_rage("Grok").(w)
      assert w.characters["Grok"].raging == false
      assert w.characters["Grok"].rage_uses_used == 1
    end

    test "ya raging: start_rage idempotente sin gasto extra" do
      w = world([barbarian(raging: true, rage_uses_used: 1)])
      {:ok, w} = World.start_rage("Grok").(w)
      assert w.characters["Grok"].raging == true
      assert w.characters["Grok"].rage_uses_used == 1
    end

    test "no-bárbaro sigue fallando (validación de clase intacta)" do
      w = world([Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12, side: "pc")])
      assert {:error, msg} = World.start_rage("Thane").(w)
      assert msg =~ "no es bárbaro"
      assert w.characters["Thane"].raging == false
    end

    test "long rest recarga usos y successes" do
      w =
        world([
          veteran(raging: false, hp: 20, rage_uses_used: 4, relentless_rage_successes: 2)
        ])

      assert {:ok, _msg, change} = Actions.long_rest(w, "Grok")
      {:ok, w2} = change.(w)
      assert w2.characters["Grok"].rage_uses_used == 0
      assert w2.characters["Grok"].relentless_rage_successes == 0

      # y puede volver a enfurecer
      {:ok, w3} = World.start_rage("Grok").(w2)
      assert w3.characters["Grok"].raging == true
      assert w3.characters["Grok"].rage_uses_used == 1
    end

    test "short rest NO recarga" do
      w = world([veteran(raging: false, hp: 5, rage_uses_used: 4, relentless_rage_successes: 1)])

      assert {:ok, _msg, change} = Actions.short_rest(w, "Grok", fixed(5))
      {:ok, w2} = change.(w)
      assert w2.characters["Grok"].rage_uses_used == 4
      assert w2.characters["Grok"].relentless_rage_successes == 0
    end
  end

  describe "Furia implacable (D72) — hook en apply_damage/4" do
    test "éxito: 0 pg → 1 pg, successes=1, nota con la tirada" do
      w = world([veteran()])

      # d20 10 + CON 7 = 17 vs CD 10 → éxito.
      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(10)).(w)
      c = w2.characters["Grok"]
      assert c.hp == 1
      assert c.relentless_rage_successes == 1
      # salvado a 1: la furia sigue viva y no se limpian flags de caído
      assert c.raging == true
      assert last_note(w2) =~ "Furia implacable"
      assert last_note(w2) =~ "vs CD 10"
      assert last_note(w2) =~ "en pie con 1 pg"
    end

    test "segundo golpe salva contra CD 15 y acumula successes" do
      w = world([veteran(relentless_rage_successes: 1)])

      # d20 10 + 7 = 17 vs CD 15 → éxito; successes 1 → 2.
      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(10)).(w)
      assert w2.characters["Grok"].hp == 1
      assert w2.characters["Grok"].relentless_rage_successes == 2
      assert last_note(w2) =~ "vs CD 15"
    end

    test "fallo: cae a 0, furia apagada, successes intactos" do
      w = world([veteran(relentless_rage_successes: 1)])

      # d20 7 + 7 = 14 vs CD 15 → fallo.
      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(7)).(w)
      c = w2.characters["Grok"]
      assert c.hp == 0
      assert c.raging == false
      assert c.relentless_rage_successes == 1
      assert last_note(w2) =~ "falla la salvación de Furia implacable"
      assert last_note(w2) =~ "vs CD 15"
    end

    test "semi-orco: fallo de Furia implacable → la RE racial salva después" do
      w = world([veteran(race: "half-orc", relentless_rage_successes: 1)])

      # 14 vs CD 15 falla la de clase; la RE racial (D67) le deja en 1.
      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(7)).(w)
      c = w2.characters["Grok"]
      assert c.hp == 1
      assert c.relentless_endurance_used == true
      assert c.relentless_rage_successes == 1
      assert c.raging == true
      assert last_note(w2) =~ "Furia implacable"
      assert last_note(w2) =~ "Resistencia implacable"
    end

    test "semi-orco: éxito de Furia implacable NO consume la RE racial" do
      w = world([veteran(race: "half-orc")])

      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(10)).(w)
      c = w2.characters["Grok"]
      assert c.hp == 1
      assert c.relentless_endurance_used == false
      assert c.relentless_rage_successes == 1
    end

    test "sin furia no aplica" do
      w = world([veteran(raging: false)])

      # d20 20 habría salvado; sin raging el hook ni se tira.
      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(20)).(w)
      assert w2.characters["Grok"].hp == 0
      assert w2.characters["Grok"].relentless_rage_successes == 0
      # sin nota nueva en el log del world
      assert length(w2.log) == length(w.log)
    end

    test "L10 no aplica (L11+)" do
      w = world([veteran(level: 10)])

      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(20)).(w)
      assert w2.characters["Grok"].hp == 0
      assert w2.characters["Grok"].relentless_rage_successes == 0
    end

    test "aura de paladín aliado (D61) suma +CHA a la salvación" do
      paladin =
        Character.new(
          name: "Paly",
          class: "paladin",
          level: 6,
          hp: 30,
          max_hp: 30,
          cha: 16,
          side: "pc"
        )

      # d20 2 + 7 = 9 < 10 sin aura; +3 del paladín CAR 16 → 12 ≥ 10 → éxito.
      w = world([veteran(), paladin])
      {:ok, w2} = World.apply_damage("Grok", 30, nil, fixed(2)).(w)
      assert w2.characters["Grok"].hp == 1
      assert last_note(w2) =~ "+3 aura"

      # mismo dado sin paladín en el side → fallo.
      {:ok, w3} = World.apply_damage("Grok", 30, nil, fixed(2)).(world([veteran()]))
      assert w3.characters["Grok"].hp == 0
    end

    test "Actions.attack hilvana su roller al save (pipe_damage)" do
      w = world([veteran(hp: 5), goblin()])

      # goblin: ataque d20 20 (crítico), dados 6+6 + FUE 3 = 15 slashing;
      # furia resiste → 7; PG 5 → 0 → save d20 10 + 7 = 17 vs CD 10 →
      # Furia implacable con el MISMO roller de la acción.
      seq = fn draws ->
        Process.put(:draws, draws)

        fn _sides ->
          [h | rest] = Process.get(:draws)
          Process.put(:draws, rest)
          h
        end
      end

      assert {:ok, _msg, change} =
               Actions.attack(w, "goblin", "Grok", "greataxe", seq.([20, 6, 6, 10]))

      {:ok, w2} = change.(w)
      assert w2.characters["Grok"].hp == 1
      assert w2.characters["Grok"].relentless_rage_successes == 1
    end
  end

  describe "Codec (D8/D72) — defaults y jsonb viejo" do
    test "Character.new arranca en 0" do
      c = Character.new(name: "X", class: "barbarian")
      assert c.rage_uses_used == 0
      assert c.relentless_rage_successes == 0
    end

    test "roundtrip preserva los contadores" do
      decoded =
        veteran(rage_uses_used: 4, relentless_rage_successes: 2)
        |> Codec.encode_character()
        |> Codec.decode_character()

      assert decoded.rage_uses_used == 4
      assert decoded.relentless_rage_successes == 2
    end

    test "jsonb viejo/ausente/malformado → 0" do
      base = Codec.encode_character(veteran())

      decoded =
        base
        |> Map.drop(["rage_uses_used", "relentless_rage_successes"])
        |> Codec.decode_character()

      assert decoded.rage_uses_used == 0
      assert decoded.relentless_rage_successes == 0

      garbage =
        Map.merge(base, %{
          "rage_uses_used" => -1,
          "relentless_rage_successes" => "mucho"
        })

      decoded = Codec.decode_character(garbage)
      assert decoded.rage_uses_used == 0
      assert decoded.relentless_rage_successes == 0
    end
  end
end
