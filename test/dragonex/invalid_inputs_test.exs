defmodule Dragonex.InvalidInputsTest do
  @moduledoc """
  Auditoría del motor, sección 7 (frente 6): ENTRADAS INVÁLIDAS.

  El LLM llama tools con argumentos rotos; el motor debe responder con un
  error útil SIN crashear y SIN mutar. Cada bloque corresponde a un hallazgo
  real (el comentario del test documenta el comportamiento previo: crash
  con ArgumentError/FunctionClauseError o mutación con datos corruptos).

  Hallazgos cubiertos:
    1. heal con expresiones de dados malformadas ("2d", "d6", "1d8+abc",
       "5", "", nil) → antes ArgumentError en Dice.parse_expr.
    2. Dice gramática: "0d6" y "1d0" pasaban la validación → cero dados o
       roller d0.
    3. roll/roll_dice con count/sides fuera de rango (0, negativos, no
       enteros, 1.5e2 desbordes) → antes FunctionClauseError en Dice.roll
       o "0d6 = 0" basura; counts gigantes colgaban la tirada.
    4. apply_damage con daño negativo → antes AUMENTABA los pg temporales
       del objetivo (mutación); no enteros contaminaban hp con floats.
    5. apply_temp_hp / grant_xp con amounts no enteros → antes
       FunctionClauseError (ninguna cláusula casaba).
    6. spawn_character / spawn_monster con nombre en blanco o pg <= 0 →
       antes creaban personajes basura (clave "" en el world).
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Dice, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp always(n), do: fn _sides -> n end

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: "goblin", class: "monster", hp: 20, max_hp: 20, ac: 12, side: "enemy"],
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

  defp dm_ctx(w) do
    game =
      start_session(
        world: w,
        policy: :round_robin,
        participants: [p("dm"), p("Sylas")]
      )

    assert {:ok, "dm"} = Session.start(game)
    %{deps: %{state: SharedState.new(game, "dm")}}
  end

  # -------------------------------------------------------------------------
  # 1. heal: expresiones de dados malformadas (crash previo: ArgumentError).
  # -------------------------------------------------------------------------

  describe "heal: dados malformados" do
    test "strings rotos devuelven error accionable sin mutar" do
      w = world([goblin(hp: 10)])

      for bad <- ["2d", "d6", "1d8+abc", "5", "", "   ", "-1d8", "0d6", "1d0", "curita", nil, 7] do
        assert {:error, msg} = Actions.heal(w, "goblin", bad, always(3), nil)
        assert msg =~ "expresión de dados inválida"
        assert msg =~ "1d8+3"
      end

      assert w.characters["goblin"].hp == 10
    end

    test "una expresión válida sigue curando (control)" do
      w = world([goblin(hp: 10)])

      assert {:ok, msg, change} = Actions.heal(w, "goblin", "1d8+3", always(4), nil)
      assert msg =~ "7 pg"
      assert elem(change.(w), 1).characters["goblin"].hp == 17
    end
  end

  # -------------------------------------------------------------------------
  # 2. Dice: la gramática rechaza cero dados y dados sin caras.
  # -------------------------------------------------------------------------

  describe "Dice: gramática estricta" do
    test "valid? rechaza 0d6 y 1d0" do
      refute Dice.valid?("0d6")
      refute Dice.valid?("1d0")
      refute Dice.valid?("0d6+2")
      assert Dice.valid?("2d6")
      assert Dice.valid?("1d8+3")
      assert Dice.valid?("10d6-2")
      refute Dice.valid?("d%")
    end

    test "valid? y parse_expr aplican los rangos sanos (revisión cruzada D96)" do
      # Gramaticalmente válidas pero capaces de colgar la tirada.
      refute Dice.valid?("101d6")
      refute Dice.valid?("1d1")
      refute Dice.valid?("1d99999")
      refute Dice.valid?("1000d8+2")

      # Límites exactos: dentro.
      assert Dice.valid?("100d6")
      assert Dice.valid?("1d1000")
      assert Dice.parse_expr("100d6") == {100, 6, 0}
      assert Dice.parse_expr("1d1000") == {1, 1000, 0}

      assert_raise ArgumentError, ~r/out of range/, fn -> Dice.parse_expr("101d6") end
      assert_raise ArgumentError, ~r/out of range/, fn -> Dice.parse_expr("1d1") end
    end

    test "heal rechaza expresiones dentro de la gramática pero fuera de rango" do
      w = world([goblin(hp: 10)])

      for bad <- ["101d8", "1d1", "1d99999"] do
        assert {:error, msg} = Actions.heal(w, "goblin", bad, always(3), nil)
        assert msg =~ "expresión de dados inválida"
        assert w.characters["goblin"].hp == 10
      end
    end

    test "parse_expr sigue aceptando expresiones legales" do
      assert Dice.parse_expr("3d8+2") == {3, 8, 2}
      assert Dice.parse_expr("1d20") == {1, 20, 0}
      assert Dice.parse_expr("2d6-1") == {2, 6, -1}
    end
  end

  # -------------------------------------------------------------------------
  # 3. roll/roll_dice: rangos numéricos (crash previo: FunctionClauseError
  #    en Dice.roll con caras <= 0; "0d6 = 0" basura; counts gigantes).
  # -------------------------------------------------------------------------

  describe "roll/roll_dice: rangos" do
    test "count y sides fuera de rango devuelven error sin rodar" do
      for {count, sides} <- [
            {0, 20},
            {-2, 20},
            {2, 0},
            {2, -6},
            {2, 1},
            {2, 2000},
            {101, 6},
            {1.5, 20},
            {2, 6.0},
            {"2", 6},
            {2, "20"},
            {nil, 6}
          ] do
        assert {:error, msg} = Actions.roll(count, sides, :normal, always(3), nil)
        assert msg =~ "tirada inválida"
      end
    end

    test "tirada válida sigue funcionando (control)" do
      assert {:ok, msg} = Actions.roll(2, 20, :normal, always(11), nil)
      assert msg =~ "tirada 2d20 = 22"
    end

    test "Tools.roll rechaza caras inválidas sin llamar al roller" do
      ctx = %{deps: %{roller: fn _sides -> raise "no debe rodarse" end}}

      for bad <- [0, -5, 1.5, "20", nil, 5000] do
        assert {:error, msg} = Tools.roll(ctx, bad)
        assert msg =~ "tirada inválida"
        assert msg =~ "2 y 1000 caras"
      end
    end

    test "Tools.roll con caras válidas rueda (control)" do
      ctx = %{deps: %{roller: fn 20 -> 17 end}}
      assert {:ok, "salió 17 (d20)"} = Tools.roll(ctx, 20)
    end
  end

  # -------------------------------------------------------------------------
  # 4. apply_damage: daño negativo o no entero (mutación previa: el daño
  #    negativo AUMENTABA los pg temporales).
  # -------------------------------------------------------------------------

  describe "apply_damage: cantidades inválidas" do
    test "daño negativo ya no infla los pg temporales" do
      w = world([goblin(temp_hp: 3)])

      assert {:error, msg} = World.apply_damage("goblin", -5).(w)
      assert msg =~ "entero no negativo"
      # Sin mutación: mismos hp y temp_hp.
      assert w.characters["goblin"].hp == 20
      assert w.characters["goblin"].temp_hp == 3
    end

    test "daño no entero se rechaza sin contaminar hp" do
      w = world([goblin()])

      for bad <- [4.5, "6", nil] do
        assert {:error, msg} = World.apply_damage("goblin", bad).(w)
        assert msg =~ "entero no negativo"
        assert w.characters["goblin"].hp == 20
      end
    end

    test "daño cero y positivo siguen funcionando (control)" do
      w = world([goblin(temp_hp: 2)])

      assert {:ok, w0} = World.apply_damage("goblin", 0).(w)
      assert w0.characters["goblin"].hp == 20

      assert {:ok, w1} = World.apply_damage("goblin", 5).(w)
      assert w1.characters["goblin"].hp == 17
      assert w1.characters["goblin"].temp_hp == 0
    end
  end

  # -------------------------------------------------------------------------
  # 5. apply_temp_hp / grant_xp: amounts no enteros (crash previo:
  #    FunctionClauseError — ninguna cláusula casaba).
  # -------------------------------------------------------------------------

  describe "apply_temp_hp / grant_xp: amounts no enteros" do
    test "temp_hp con amount no entero devuelve error" do
      w = world([goblin()])

      for bad <- [2.5, "5", nil] do
        assert {:error, msg} = World.apply_temp_hp("goblin", bad).(w)
        assert msg =~ "entero positivo"
        assert w.characters["goblin"].temp_hp == 0
      end
    end

    test "grant_xp con amount no entero devuelve error" do
      w = world([goblin()])

      for bad <- [10.5, "100", nil] do
        assert {:error, msg} = World.grant_xp("goblin", bad).(w)
        assert msg =~ "entero positivo"
        assert w.characters["goblin"].xp == 0
      end
    end

    test "valores enteros positivos siguen aplicándose (control)" do
      w = world([goblin()])

      assert {:ok, w1} = World.apply_temp_hp("goblin", 5).(w)
      assert w1.characters["goblin"].temp_hp == 5

      assert {:ok, w2} = World.grant_xp("goblin", 50).(w1)
      assert w2.characters["goblin"].xp == 50
    end
  end

  # -------------------------------------------------------------------------
  # 6. spawn: nombre en blanco o pg sin sentido (previo: personajes basura
  #    con clave "" en el world).
  # -------------------------------------------------------------------------

  describe "spawn_character / spawn_monster: nombre y pg" do
    test "spawn_character rechaza nombre en blanco sin mutar" do
      ctx = dm_ctx(world([goblin()]))

      for bad <- ["", "   ", nil, 42] do
        assert {:error, msg} = Tools.spawn_character(ctx, bad, 10)
        assert msg =~ "nombre inválido"
      end

      assert {:error, _} = Tools.spawn_character(ctx, "orco", 0)
      assert {:error, _} = Tools.spawn_character(ctx, "orco", -5)
      assert {:error, _} = Tools.spawn_character(ctx, "orco", 7.5)

      assert {:error, msg2} = Tools.spawn_character(ctx, "orco", 0)
      assert msg2 =~ "entero ≥ 1"
    end

    test "spawn_character válido sigue funcionando (control)" do
      ctx = dm_ctx(world([]))

      assert {:ok, msg} = Tools.spawn_character(ctx, "orco", 12)
      assert msg =~ "orco aparece (12 pg)"
    end

    test "spawn_monster rechaza nombre en blanco sin mutar" do
      ctx = dm_ctx(world([goblin()]))

      for bad <- ["", "   ", nil] do
        assert {:error, msg} = Tools.spawn_monster(ctx, "goblin", bad)
        assert msg =~ "nombre inválido"
      end
    end

    test "spawn_monster válido sigue funcionando (control)" do
      ctx = dm_ctx(world([]))

      assert {:ok, msg} = Tools.spawn_monster(ctx, "goblin", "Grib")
      assert msg =~ "Aparece Grib (goblin)"
    end
  end

  # -------------------------------------------------------------------------
  # Regresiones de contrato: errores ya existentes que deben seguir igual.
  # -------------------------------------------------------------------------

  describe "validaciones preexistentes intactas" do
    test "cast_level no entero y trucos a nivel superior siguen rechazándose" do
      w =
        world([
          Character.new(
            name: "Lyra",
            class: "wizard",
            level: 1,
            hp: 20,
            max_hp: 20,
            ac: 12,
            side: "pc",
            spells: [
              %Dragonex.Spell{
                name: "fire bolt",
                level: 0,
                kind: :attack,
                casting_ability: :int,
                dice: "1d10",
                damage_type: "fire"
              }
            ]
          ),
          goblin()
        ])

      assert {:error, msg} = Actions.spell(w, "Lyra", "fire bolt", "goblin", always(3), nil, 2)
      assert msg =~ "no se pueden lanzar a nivel superior"

      assert {:error, msg2} = Actions.spell(w, "Lyra", "fire bolt", "goblin", always(3), nil, 1.5)
      assert msg2 =~ "nivel de lanzamiento inválido"
    end

    test "divine_smite fuera de 1..5 sigue rechazándose" do
      w = world([goblin()])

      for bad <- [0, 6, -1, 2.5] do
        assert {:error, msg} = World.start_smite("goblin", bad).(w)
        assert msg =~ "entre 1 y 5"
      end
    end

    test "advance_time negativo o no entero sigue rechazándose" do
      w = world([])

      for bad <- [-60, 1.5, "60"] do
        assert {:error, msg} = World.advance_time(bad).(w)
        assert msg =~ "entero no negativo"
      end
    end
  end
end
