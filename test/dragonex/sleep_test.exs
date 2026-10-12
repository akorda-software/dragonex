defmodule Dragonex.SleepTest do
  @moduledoc """
  Sleep ejecutable (ADR D96). HOY (rojo): el builtin 5d8 sin damage_type
  caía en la rama de CURACIÓN de :automatic y curaba al enemigo apuntado
  (hp SUBÍA). Ahora: pool RAW 5d8 (+2d8/nivel sobre 1), sin salvación,
  enemigos vivos/conscientes por PG ascendente, reparto de menor a mayor,
  la primera criatura que no cabe detiene todo, 1 minuto de duración,
  despertar al recibir daño (el daño se aplica normal), Twinned no duplica
  el pool, errores no mutan.

  Rollers fijos → oráculos con conteo exacto de dados (pool = NdM exacto).
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Rules.Upcast, Spell, World}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp spent?, do: Process.get(:seq, [])

  defp sheet_spell(name, level, kind, dice, opts \\ []) do
    %Spell{
      name: name,
      level: level,
      kind: kind,
      casting_ability: Keyword.get(opts, :casting_ability, :int),
      dice: dice,
      damage_type: Keyword.get(opts, :damage_type),
      save_ability: Keyword.get(opts, :save_ability)
    }
  end

  defp wizard(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Lyra",
          class: "wizard",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 16,
          wis: 12,
          cha: 10,
          side: "pc",
          spells: [sheet_spell("sleep", 1, :automatic, "5d8")]
        ],
        opts
      )
    )
  end

  defp sorcerer(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Sylas",
          class: "sorcerer",
          level: 5,
          hp: 28,
          max_hp: 28,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 10,
          wis: 12,
          cha: 16,
          side: "pc",
          sorcery_points: 5,
          spells: [
            sheet_spell("sleep", 1, :automatic, "5d8", casting_ability: :cha)
          ]
        ],
        opts
      )
    )
  end

  defp foe(name, hp, opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: name, class: "monster", hp: hp, max_hp: hp, ac: 12, side: "enemy", dex: 12],
        opts
      )
    )
  end

  defp world(chars) do
    chars
    |> Enum.reduce(World.new(phase: :combat), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  defp turn!(w, name) do
    {:ok, w} = World.set_current_combatant(name).(w)
    w
  end

  defp cast!(w, caster, target, roller, cast_level \\ nil) do
    assert {:ok, _msg, change} =
             Actions.spell(w, caster, "sleep", target, roller, nil, cast_level)

    elem(change.(w), 1)
  end

  defp asleep?(w, name) do
    Enum.any?(w.characters[name].conditions, fn
      %{"condition" => "unconscious", "source" => "sleep:" <> _} -> true
      _ -> false
    end)
  end

  describe "Rules.Upcast (fila sleep)" do
    test "+2d8 por nivel sobre el 1º" do
      assert Upcast.extra_dice("sleep", 1, 2) == "2d8"
      assert Upcast.extra_dice("sleep", 1, 3) == "4d8"
      assert Upcast.extra_dice("sleep", 1, 1) == nil

      # La base 5d8 se combina en UNA expresión: conteo exacto de dados.
      spell = sheet_spell("sleep", 1, :automatic, "5d8")
      assert Upcast.scaled_spell(spell, 2).dice == "7d8"
      assert Upcast.scaled_spell(spell, 3).dice == "9d8"
    end
  end

  describe "pool RAW" do
    test "ya no cura al enemigo: duerme por PG ascendente y el hp no cambia" do
      w = world([wizard(), foe("kobold", 5, max_hp: 20, hp: 5), foe("goblin", 10)])
      w = turn!(w, "Lyra")

      # Pool 5d8 con roller 4 → 20. Orden asc: kobold (5) duerme (pool 15),
      # goblin (10) duerme (pool 5). El hp de ambos queda INTACTO.
      w2 = cast!(w, "Lyra", "goblin", seq([4, 4, 4, 4, 4]))
      assert spent?() == []

      assert asleep?(w2, "kobold")
      assert asleep?(w2, "goblin")
      assert w2.characters["kobold"].hp == 5
      assert w2.characters["goblin"].hp == 10
      # La casilla de nivel 1 se gastó (2 → 1).
      assert w2.spell_slots["Lyra"][1] == 1
    end

    test "la primera criatura que no cabe detiene el reparto" do
      w = world([wizard(), foe("rat", 5), foe("goblin", 12), foe("orco", 18)])
      w = turn!(w, "Lyra")

      # Pool 15: rat (5) duerme → resto 10; goblin (12) NO cabe → para.
      # Orco (18) ni se evalúa.
      w2 = cast!(w, "Lyra", "rat", seq([3, 3, 3, 3, 3]))
      assert asleep?(w2, "rat")
      refute asleep?(w2, "goblin")
      refute asleep?(w2, "orco")

      assert {:ok, msg, _} = Actions.spell(w, "Lyra", "sleep", "rat", seq([3, 3, 3, 3, 3]), nil)
      assert msg =~ "goblin (12 pg) resiste"
      assert msg =~ "resto del pool (10)"
    end

    test "empate de PG: orden por nombre (determinista)" do
      w = world([wizard(), foe("briv", 8), foe("arlo", 8)])
      w = turn!(w, "Lyra")

      # Pool 9: arlo (8) duerme, briv (8) no cabe (resto 1).
      w2 = cast!(w, "Lyra", "arlo", seq([3, 2, 2, 1, 1]))
      assert asleep?(w2, "arlo")
      refute asleep?(w2, "briv")
    end

    test "upcast a nivel 2 tira exactamente 7d8" do
      # L3 para tener casillas de nivel 2 (2×L2).
      w = world([wizard(level: 3), foe("goblin", 13)])
      w = turn!(w, "Lyra")

      # 7 dados de 2 → pool 14 ≥ 13: duerme.
      w2 = cast!(w, "Lyra", "goblin", seq([2, 2, 2, 2, 2, 2, 2]), 2)
      assert spent?() == []
      assert asleep?(w2, "goblin")
      assert w2.spell_slots["Lyra"][2] == 1
    end
  end

  describe "exclusiones y área abstracta" do
    test "caídos, muertos e inconscientes previos quedan fuera; los aliados nunca" do
      %Character{} = base = wizard()
      ally = %Character{base | name: "Thane", side: "pc"}

      downed = foe("caido", 0)

      sleeper =
        foe("dormido", 9, conditions: [%{"condition" => "unconscious", "source" => "otro"}])

      w = world([wizard(), ally, downed, sleeper, foe("goblin", 10)])
      w = turn!(w, "Lyra")

      # Pool 20: solo el goblin (10) es objetivo → duerme; aliado intacto.
      w2 = cast!(w, "Lyra", "goblin", seq([4, 4, 4, 4, 4]))
      assert asleep?(w2, "goblin")
      refute asleep?(w2, "dormido")
      refute asleep?(w2, "caido")
      refute asleep?(w2, "Thane")
      assert w2.characters["Thane"].hp == 20
    end

    test "sin enemigos válidos: mensaje claro y sin mutación de condiciones" do
      w = world([wizard(), foe("caido", 0)])
      w = turn!(w, "Lyra")

      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "sleep", "caido", seq([1, 1, 1, 1, 1]), nil)

      assert msg =~ "no hay enemigos que duerman"
      w2 = elem(change.(w), 1)
      assert w2.characters["caido"].conditions == []
      # La casilla se gasta igual (RAW): 2 → 1.
      assert w2.spell_slots["Lyra"][1] == 1
    end
  end

  describe "despertar por daño" do
    test "el daño se aplica normal y quita el sueño" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")
      w = cast!(w, "Lyra", "goblin", seq([4, 4, 4, 4, 4]))
      assert asleep?(w, "goblin")

      {:ok, w2} = World.apply_damage("goblin", 4).(w)
      assert w2.characters["goblin"].hp == 6
      refute asleep?(w2, "goblin")
    end

    test "daño absorbido por pg temporales también despierta" do
      w = world([wizard(), foe("goblin", 10, temp_hp: 3)])
      w = turn!(w, "Lyra")
      w = cast!(w, "Lyra", "goblin", seq([4, 4, 4, 4, 4]))

      {:ok, w2} = World.apply_damage("goblin", 2).(w)
      assert w2.characters["goblin"].hp == 10
      assert w2.characters["goblin"].temp_hp == 1
      refute asleep?(w2, "goblin")
    end

    test "un inconsciente por OTRA causa no se toca" do
      w = world([wizard(), foe("goblin", 10, conditions: ["unconscious"])])
      w = turn!(w, "Lyra")

      {:ok, w2} = World.apply_damage("goblin", 2).(w)
      assert "unconscious" in w2.characters["goblin"].conditions
    end
  end

  describe "Twinned y errores" do
    test "Twinned no duplica el pool ni consume la opción" do
      w = world([sorcerer(), foe("goblin", 10), foe("kobold", 5)])
      w = turn!(w, "Sylas")
      {:ok, w} = World.set_metamagic("Sylas", %{option: "twinned", target: "kobold"}).(w)

      # Un solo pool de 5d8 (5 dados exactos): orden asc kobold(5)+goblin(10)
      # = 15 ≤ 20 → ambos duermen; el gasto de dados es el de UNA resolución.
      w2 = cast!(w, "Sylas", "goblin", seq([4, 4, 4, 4, 4]))
      assert spent?() == []
      assert asleep?(w2, "kobold")
      assert asleep?(w2, "goblin")
      # La opción sigue armada (no se aplicó ni se consumió).
      assert w2.characters["Sylas"].metamagic == %{option: "twinned", target: "kobold"}
    end

    test "cast_level 0: error sin mutar" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")

      assert {:error, msg} = Actions.spell(w, "Lyra", "sleep", "goblin", seq([1]), nil, 0)
      assert msg =~ "nivel mínimo de este hechizo es 1"
      assert w.characters["goblin"].hp == 10
      assert spent?() == [1]
    end
  end
end
