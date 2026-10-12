defmodule Dragonex.CantripsTest do
  @moduledoc """
  Escalado RAW de trucos por NIVEL DE PERSONAJE y dados builtin (ADR D95):

    * Umbrales 5/11/17 → 2/3/4 dados; NUNCA `cast_level` (D74 sigue
      prohibiendo el upcast de trucos).
    * Hojas rancias: cast_spell rellena los campos `nil` con el catálogo
      (builtin gana al SRD) — sacred flame con `dice: null` persistido ya
      no hace 0/null.
    * Eldritch Blast: equivalencia documentada en dados extra sobre una
      sola tirada (1d10→2d10→3d10→4d10).
    * Acid splash: RAW 2 objetivos, simplificado a 1 (D95).

  Rollers fijos → oráculos con conteo exacto de dados consumidos.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Rules.Cantrips, Spell, World}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp spent?, do: Process.get(:seq, [])

  defp sheet_spell(name, kind, dice, opts \\ []) do
    %Spell{
      name: name,
      level: 0,
      kind: kind,
      casting_ability: Keyword.get(opts, :casting_ability, :int),
      dice: dice,
      damage_type: Keyword.get(opts, :damage_type),
      save_ability: Keyword.get(opts, :save_ability),
      effect: Keyword.get(opts, :effect)
    }
  end

  defp hero(opts) do
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
          spells: [sheet_spell("fire bolt", :attack, "1d10", damage_type: "fire")]
        ],
        opts
      )
    )
  end

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: "goblin", class: "monster", hp: 40, max_hp: 40, ac: 12, side: "enemy", dex: 12],
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

  # Lyra L5: INT 16 (+3), prof 3 → ataque +6, CD 14. Goblin CA 12, DES +1.

  describe "Rules.Cantrips (tabla curada)" do
    test "umbrales RAW 5/11/17 sobre las caras base" do
      assert Cantrips.scaled_dice("fire bolt", 1) == "1d10"
      assert Cantrips.scaled_dice("fire bolt", 4) == "1d10"
      assert Cantrips.scaled_dice("fire bolt", 5) == "2d10"
      assert Cantrips.scaled_dice("fire bolt", 10) == "2d10"
      assert Cantrips.scaled_dice("fire bolt", 11) == "3d10"
      assert Cantrips.scaled_dice("fire bolt", 16) == "3d10"
      assert Cantrips.scaled_dice("fire bolt", 17) == "4d10"
      assert Cantrips.scaled_dice("fire bolt", 20) == "4d10"
    end

    test "caras base por truco y tolerancia de nombre" do
      assert Cantrips.scaled_dice("Ray of Frost", 5) == "2d8"
      assert Cantrips.scaled_dice("chill touch", 11) == "3d8"
      assert Cantrips.scaled_dice("produce flame", 17) == "4d8"
      assert Cantrips.scaled_dice("shocking grasp", 5) == "2d8"
      assert Cantrips.scaled_dice("sacred flame", 5) == "2d8"
      assert Cantrips.scaled_dice("vicious mockery", 17) == "4d4"
      assert Cantrips.scaled_dice("poison spray", 11) == "3d12"
      assert Cantrips.scaled_dice("acid splash", 5) == "2d6"
      assert Cantrips.scaled_dice("eldritch blast", 17) == "4d10"
    end

    test "fuera de tabla no escala y nil level usa la base" do
      assert Cantrips.scaled_dice("light", 20) == nil
      assert Cantrips.scaled_dice("magic missile", 20) == nil
      assert Cantrips.scaled_dice("fire bolt", nil) == "1d10"
    end

    test "scaled_spell solo toca trucos de la tabla" do
      assert Cantrips.scaled_spell(
               sheet_spell("fire bolt", :attack, "1d10", damage_type: "fire"),
               5
             ).dice ==
               "2d10"

      # Un truco fuera de tabla (automatic, sin dados) sale intacto.
      light = sheet_spell("light", :automatic, nil)
      assert Cantrips.scaled_spell(light, 20) == light

      # Un hechizo de nivel > 0 nunca escala por nivel de personaje.
      fireball = %Spell{name: "fireball", level: 3, kind: :save, dice: "8d6", damage_type: "fire"}
      assert Cantrips.scaled_spell(fireball, 20) == fireball
    end
  end

  describe "escalado en cast_spell (oráculos con dados inyectados)" do
    test "fire bolt L1 tira exactamente 1d10" do
      w = world([hero(level: 1), goblin()])
      roller = seq([15, 6])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "fire bolt", "goblin", roller, nil)
      assert msg =~ "6 de daño de fuego"
      assert spent?() == []
    end

    test "fire bolt L5 tira exactamente 2d10 (hoy no escalaba)" do
      w = world([hero(level: 5), goblin()])
      roller = seq([15, 10, 4])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "fire bolt", "goblin", roller, nil)
      assert msg =~ "14 de daño de fuego"
      assert spent?() == []
    end

    test "ray of frost L11 tira exactamente 3d8" do
      w =
        world([
          hero(
            level: 11,
            spells: [sheet_spell("ray of frost", :attack, "1d8", damage_type: "cold")]
          ),
          goblin()
        ])

      roller = seq([15, 2, 2, 2])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "ray of frost", "goblin", roller, nil)
      assert msg =~ "6 de daño de frío"
      assert spent?() == []
    end

    test "eldritch blast L5: equivalencia en dados extra sobre una tirada (D95)" do
      w =
        world([
          hero(
            class: "warlock",
            level: 5,
            spells: [sheet_spell("eldritch blast", :attack, "1d10", damage_type: "force")]
          ),
          goblin()
        ])

      roller = seq([15, 10, 10])

      assert {:ok, msg, _change} =
               Actions.spell(w, "Lyra", "eldritch blast", "goblin", roller, nil)

      assert msg =~ "20 de daño de fuerza"
      assert spent?() == []
    end

    test "fire bolt L17 tira 4d10" do
      w = world([hero(level: 17), goblin()])
      roller = seq([15, 1, 1, 1, 1])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "fire bolt", "goblin", roller, nil)
      assert msg =~ "4 de daño de fuego"
      assert spent?() == []
    end
  end

  describe "hojas rancias: overlay del catálogo en cast (D95)" do
    test "sacred flame con dice nil ya no hace 0/null: 1d8 radiante, save DES" do
      # Hoja pre-builtin tal como la decodificaría un jsonb viejo del SRD.
      stale =
        sheet_spell("sacred flame", :save, nil,
          casting_ability: :wis,
          save_ability: nil,
          damage_type: nil
        )

      w = world([hero(class: "cleric", level: 4, wis: 16, int: 10, spells: [stale]), goblin()])

      # Salvación DES del goblin (d20 10 + 1 = 11) falla vs CD 13 → 1d8 completo.
      roller = seq([10, 8])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "sacred flame", "goblin", roller, nil)
      assert msg =~ "8 de daño radiante"
      # El total 11 = d20 10 + DES +1: la salvación rodada es Destreza.
      assert msg =~ "11 vs CD 13"
      assert spent?() == []
    end

    test "poison spray builtin: 1d12 veneno, salvación CON" do
      stale = sheet_spell("poison spray", :save, nil, casting_ability: :wis)

      w = world([hero(class: "druid", level: 4, wis: 16, int: 10, spells: [stale]), goblin()])

      # Goblin CON 10 → d20 5 falla vs CD 13 → 12 de veneno.
      roller = seq([5, 12])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "poison spray", "goblin", roller, nil)
      assert msg =~ "12 de daño de veneno"
      # Total 5 = d20 5 + CON +0: la salvación rodada es Constitución.
      assert msg =~ "5 vs CD 13"
      assert spent?() == []
    end

    test "vicious mockery builtin: 1d4 psíquico, salvación SAB" do
      stale = sheet_spell("vicious mockery", :save, nil, casting_ability: :cha)

      w = world([hero(class: "bard", level: 4, cha: 16, int: 10, spells: [stale]), goblin()])

      roller = seq([10, 4])

      assert {:ok, msg, _change} =
               Actions.spell(w, "Lyra", "vicious mockery", "goblin", roller, nil)

      assert msg =~ "4 de daño psíquico"
      # Total 10 = d20 10 + SAB +0: la salvación rodada es Sabiduría.
      assert msg =~ "10 vs CD 13"
      assert spent?() == []
    end

    test "acid splash builtin: 1d6 ácido, salvación DES, un solo objetivo (D95)" do
      stale = sheet_spell("acid splash", :save, nil, casting_ability: :int)

      w = world([hero(level: 1, spells: [stale]), goblin()])

      # L1: CD 8 + 2 + 3 = 13; goblin d20 10 + 1 = 11 falla → 6 ácido.
      roller = seq([10, 6])

      assert {:ok, msg, _change} = Actions.spell(w, "Lyra", "acid splash", "goblin", roller, nil)
      assert msg =~ "6 de daño de ácido"
      assert spent?() == []
    end

    test "el overlay nunca pisa datos no-nulos de la ficha" do
      # burning hands no es truco: sin overlay-pisado ni escalado de nivel
      # de personaje, los 3d6 explícitos de la hoja salen intactos.
      burning =
        %Spell{
          name: "burning hands",
          level: 1,
          kind: :save,
          casting_ability: :int,
          dice: "2d6",
          damage_type: "fire",
          save_ability: :dex
        }

      w = world([hero(level: 20, spells: [burning]), goblin()])

      # Salvación falla (10+1 < CD 17) → 2d6 completos = 6.
      roller = seq([10, 3, 3])

      assert {:ok, msg, _change} =
               Actions.spell(w, "Lyra", "burning hands", "goblin", roller, nil)

      assert msg =~ "6 de daño de fuego"
      assert spent?() == []
    end
  end

  describe "errores y no-mutación" do
    test "upcast de truco sigue prohibido (D74) y no muta" do
      w = world([hero(level: 5), goblin()])

      assert {:error, msg} =
               Actions.spell(w, "Lyra", "fire bolt", "goblin", fn _ -> 1 end, nil, 2)

      assert msg =~ "no se pueden lanzar a nivel superior"
      assert w.characters["goblin"].hp == 40
    end

    test "truco desconocido: error sin consumo de dados" do
      w = world([hero(level: 1), goblin()])
      roller = seq([15, 6])

      assert {:error, _} = Actions.spell(w, "Lyra", "mending", "goblin", roller, nil)
      assert spent?() == [15, 6]
    end
  end
end
