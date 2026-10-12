defmodule Dragonex.ShieldTest do
  @moduledoc """
  Shield ejecutable (ADR D96). HOY (rojo): shield era un noop narrativo
  (:automatic sin dados → "conjura shield sobre X"). Ahora: postura armable
  en el turno propio (patrón D64) que da +5 a la CA EFECTIVA
  (Effects.effective_ac, sin mutar c.ac) hasta el inicio del siguiente
  turno del lanzador (barrido eager en set_current_combatant/end_combat),
  consume 1 casilla de nivel 1, rearmar renueva sin apilar, magic missile
  hace 0 daño al portador.

  Rollers fijos → oráculos con conteo exacto de dados.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Brief, Character, Rules.Effects, Spell, World, Weapon}

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
          level: 3,
          hp: 24,
          max_hp: 24,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 16,
          wis: 12,
          cha: 10,
          side: "pc",
          spells: [
            sheet_spell("shield", 1, :automatic, nil),
            sheet_spell("magic missile", 1, :automatic, "3d4+3", damage_type: "force")
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

  defp foe_wizard do
    foe("mago malo", 18,
      class: "wizard",
      int: 16,
      spells: [sheet_spell("magic missile", 1, :automatic, "3d4+3", damage_type: "force")]
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

  defp arm!(w, who) do
    assert {:ok, _msg, change} = Actions.spell(w, who, "shield", who, fn _ -> 1 end, nil)
    elem(change.(w), 1)
  end

  defp shielded?(w, name), do: Effects.shielded?(w.characters[name])

  # Lyra L3: CA 12 → 17 con la postura.

  describe "armar la postura" do
    test "+5 en CA efectiva sin mutar la base; gasta casilla nivel 1; sin dados" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")

      w2 = arm!(w, "Lyra")

      assert shielded?(w2, "Lyra")
      assert w2.characters["Lyra"].ac == 12
      assert Effects.effective_ac(w2.characters["Lyra"]) == 17
      assert Effects.effective_ac(w.characters["Lyra"]) == 12
      # 4 casillas de nivel 1 → 3.
      assert w2.spell_slots["Lyra"][1] == 3
    end

    test "el brief de CA (D94) muestra la efectiva con base" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")
      w2 = arm!(w, "Lyra")

      line =
        w2
        |> Brief.world_brief("dm")
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "- Lyra "))

      assert line =~ "CA 17 (base 12)"
    end

    test "objetivo distinto del lanzador: error sin mutar" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")

      assert {:error, msg} = Actions.spell(w, "Lyra", "shield", "goblin", fn _ -> 1 end, nil)
      assert msg =~ "Shield solo puede tener como objetivo al propio lanzador"
      assert w.spell_slots["Lyra"][1] == 4
    end

    test "fuera de combate: error claro sin mutar" do
      w =
        [wizard(), foe("goblin", 10)]
        |> Enum.reduce(World.new(), fn c, w ->
          {:ok, w} = World.add_character(c).(w)
          w
        end)
        |> World.init_spell_slots()

      assert {:error, msg} = Actions.spell(w, "Lyra", "shield", "Lyra", fn _ -> 1 end, nil)
      assert msg =~ "solo puede tejerse en combate"
      refute shielded?(w, "Lyra")
    end

    test "rearmar renueva: una sola entrada, no apila" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")
      w = arm!(w, "Lyra")

      # Ronda 2, turno nuevo de Lyra (la vieja expiró al empezarlo).
      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Lyra")
      w2 = arm!(w, "Lyra")

      entries =
        Enum.filter(w2.characters["Lyra"].conditions, &match?(%{"condition" => "shielded"}, &1))

      assert length(entries) == 1
      assert Effects.effective_ac(w2.characters["Lyra"]) == 17
    end
  end

  describe "expiración" do
    test "muere al INICIO del siguiente turno del lanzador" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")
      w = arm!(w, "Lyra")
      assert shielded?(w, "Lyra")

      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Lyra")
      refute shielded?(w, "Lyra")
      assert Effects.effective_ac(w.characters["Lyra"]) == 12
    end

    test "re-seleccionar en el MISMO turno no la toca" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")
      w = arm!(w, "Lyra")

      w = turn!(w, "Lyra")
      assert shielded?(w, "Lyra")
    end

    test "end_combat la disuelve" do
      w = world([wizard(), foe("goblin", 10)])
      w = turn!(w, "Lyra")
      w = arm!(w, "Lyra")

      {:ok, w} = World.end_combat().(w)
      refute shielded?(w, "Lyra")
    end
  end

  describe "magic missile y ataques" do
    test "magic missile hace 0 daño al portador (conteo exacto: 3 dardos)" do
      w = world([wizard(), foe_wizard()])
      w = turn!(w, "Lyra")
      w = arm!(w, "Lyra")
      w = turn!(w, "mago malo")

      assert {:ok, msg, _} =
               Actions.spell(w, "mago malo", "magic missile", "Lyra", seq([4, 4, 4]), nil)

      assert msg =~ "escudo arcano"
      assert msg =~ "0 de daño de fuerza"
      assert spent?() == []
      assert w.characters["Lyra"].hp == 24
    end

    test "sin la postura, el mismo magic missile daña (control)" do
      w = world([wizard(), foe_wizard()])
      w = turn!(w, "mago malo")

      assert {:ok, msg, change} =
               Actions.spell(w, "mago malo", "magic missile", "Lyra", seq([4, 4, 4]), nil)

      assert msg =~ "15 de daño de fuerza"
      w2 = elem(change.(w), 1)
      assert w2.characters["Lyra"].hp == 9
    end

    test "un ataque que rozaba la CA base ahora falla" do
      goblin =
        foe("goblin", 10,
          str: 15,
          weapons: [
            %Weapon{name: "espada", dice: "1d6", damage_type: "slashing", attack_ability: :str}
          ]
        )

      w = world([wizard(), goblin])
      w = turn!(w, "Lyra")
      w = arm!(w, "Lyra")
      w = turn!(w, "goblin")

      # Ataque +4 (FUE+2, prof+2): d20 12 → 16. CA base 12: impacto;
      # CA efectiva 17: fallo (un solo d20, sin dados de daño).
      assert {:ok, msg, _} = Actions.attack(w, "goblin", "Lyra", "espada", seq([12]))
      assert msg =~ "fallo"
      assert w.characters["Lyra"].hp == 24
      assert spent?() == []
    end

    test "apila con Shield of Faith (+2) y Defense (+1): 12+1+2+5 = 20" do
      caster = %{
        wizard()
        | name: "Mira",
          class: "cleric",
          fighting_style: "defense",
          conditions: [
            %{
              "condition" => "shield_of_faith",
              "concentration" => "shield of faith",
              "source" => "Mira"
            },
            %{"condition" => "shielded", "source" => "Mira"}
          ]
      }

      assert Effects.effective_ac(caster) == 20
    end
  end
end
