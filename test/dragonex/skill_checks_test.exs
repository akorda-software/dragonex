defmodule Dragonex.SkillChecksTest do
  @moduledoc """
  Proficiency de skills en `ability_check` + Jack of All Trades del bardo
  (D60 / M44): arregla el hueco v1 (la tool ignoraba
  `Character.skill_proficiencies`). La tool `ability_check` acepta un skill
  ("stealth", "Animal Handling", "animal-handling" — normalizado) o una
  característica cruda (str/dex/con/int/wis/cha, compat hacia atrás). El skill
  mapea su característica (`Rules.Skills`), aplica prof completa si está
  entrenado y, si no, mitad de prof (floor) a un bardo L2+ (JoaT). Nunca
  ambos. Sin Expertise, tools/instrumentos, Reliable Talent, feats ni
  multiclase.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Tools, World}
  alias Dragonex.Rules.{Combat, Skills}
  alias ExAgent.{Session, Session.SharedState}

  defp always(value), do: Dragonex.Dice.always(value)

  defp rogue(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Vex",
          class: "rogue",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 15,
          str: 10,
          dex: 16,
          con: 12,
          wis: 10,
          cha: 10,
          side: "pc",
          skill_proficiencies: ["stealth"],
          weapons: []
        ],
        opts
      )
    )
  end

  defp bard(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Lira",
          class: "bard",
          level: 2,
          hp: 14,
          max_hp: 14,
          ac: 13,
          str: 8,
          dex: 14,
          con: 12,
          int: 10,
          wis: 10,
          cha: 16,
          side: "pc",
          skill_proficiencies: ["persuasion"],
          weapons: []
        ],
        opts
      )
    )
  end

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "goblin",
          class: "monster",
          level: 1,
          hp: 10,
          max_hp: 10,
          ac: 12,
          dex: 14,
          side: "enemy"
        ],
        opts
      )
    )
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  describe "Rules.Skills — tabla y normalización" do
    test "los 18 skills SRD mapean su característica" do
      expected = %{
        "athletics" => :str,
        "acrobatics" => :dex,
        "sleight_of_hand" => :dex,
        "stealth" => :dex,
        "arcana" => :int,
        "history" => :int,
        "investigation" => :int,
        "nature" => :int,
        "religion" => :int,
        "animal_handling" => :wis,
        "insight" => :wis,
        "medicine" => :wis,
        "perception" => :wis,
        "survival" => :wis,
        "deception" => :cha,
        "intimidation" => :cha,
        "performance" => :cha,
        "persuasion" => :cha
      }

      assert length(Skills.all()) == 18

      for {skill, ability} <- expected do
        assert {:ok, ^ability} = Skills.ability(skill)
        assert Skills.known?(skill)
      end
    end

    test "intimidation es CAR, no INT (el parse de ability es por prefijo)" do
      # Regresión del orden de detección: skill ANTES que ability.
      assert {:ok, :cha} = Skills.ability("intimidation")
    end

    test "normalize acepta espacios, guiones y mayúsculas" do
      assert Skills.normalize("Animal Handling") == "animal_handling"
      assert Skills.normalize("animal-handling") == "animal_handling"
      assert Skills.normalize("  ANIMAL HANDLING ") == "animal_handling"
      assert Skills.normalize(:"Sleight of Hand") == "sleight_of_hand"
      assert Skills.normalize("stealth") == "stealth"
    end

    test "known?/1 con basura → false sin explotar" do
      refute Skills.known?("cooking")
      refute Skills.known?("")
      refute Skills.known?(12_345)
      assert Skills.known?("Stealth")
      assert :error = Skills.ability("cooking")
    end
  end

  describe "Combat.check_proficiency/2" do
    test "entrenado → prof completa" do
      assert {2, :prof} = Combat.check_proficiency(rogue(), true)
    end

    test "sin entrenar y no bardo → 0 (como v1)" do
      assert {0, :none} = Combat.check_proficiency(rogue(), false)
      assert {0, :none} = Combat.check_proficiency(goblin(), false)
    end

    test "bardo L2+ sin entrenar → mitad (floor)" do
      # L2: prof 2 → 1. L5: prof 3 → 1. L9: prof 4 → 2.
      assert {1, :joat} = Combat.check_proficiency(bard(level: 2), false)
      assert {1, :joat} = Combat.check_proficiency(bard(level: 5), false)
      assert {2, :joat} = Combat.check_proficiency(bard(level: 9), false)
    end

    test "bardo L1 sin entrenar → 0; bardo entrenado → prof completa (nunca ambos)" do
      assert {0, :none} = Combat.check_proficiency(bard(level: 1), false)
      assert {2, :prof} = Combat.check_proficiency(bard(level: 2), true)
    end
  end

  describe "Actions.check — skill pasado por nombre" do
    test "skill entrenado aplica prof completa (mensaje ES con desglose)" do
      w = world([rogue()])

      # 1d20(11) + DES 3 + prof 2 = 16 vs CD 15 — éxito
      assert {:ok, msg, _} = Actions.check(w, "Vex", "stealth", 15, false, always(11))

      assert msg =~ "chequeo de Sigilo (DES)"
      assert msg =~ "1d20(11) + DES 3 + prof 2 = 16 vs CD 15 — éxito"
      refute msg =~ "JoaT"
    end

    test "skill sin entrenar y no bardo → sin prof" do
      w = world([rogue(skill_proficiencies: [])])

      assert {:ok, msg, _} = Actions.check(w, "Vex", "stealth", 15, false, always(11))

      assert msg =~ "chequeo de Sigilo (DES)"
      assert msg =~ "1d20(11) + DES 3 = 14 vs CD 15 — fallo"
      refute msg =~ "prof"
      refute msg =~ "JoaT"
    end

    test "bardo L2 sin entrenar → JoaT (mitad de prof)" do
      w = world([bard(level: 2)])

      # persuasion entrenada; usamos deception (CAR, sin entrenar):
      # 1d20(10) + CAR 3 + JoaT 1 = 14 vs CD 12 — éxito
      assert {:ok, msg, _} = Actions.check(w, "Lira", "deception", 12, false, always(10))

      assert msg =~ "chequeo de Engaño (CAR)"
      assert msg =~ "1d20(10) + CAR 3 + JoaT 1 = 14 vs CD 12 — éxito"
    end

    test "bardo L5 sin entrenar → prof 3, JoaT floor 1" do
      w = world([bard(level: 5)])

      assert {:ok, msg, _} = Actions.check(w, "Lira", "stealth", 10, false, always(10))

      # DES +2 (dex 14): 10 + 2 + 1 = 13
      assert msg =~ "1d20(10) + DES 2 + JoaT 1 = 13 vs CD 10 — éxito"
    end

    test "bardo L1 sin entrenar → sin JoaT" do
      w = world([bard(level: 1)])

      assert {:ok, msg, _} = Actions.check(w, "Lira", "deception", 10, false, always(10))

      assert msg =~ "1d20(10) + CAR 3 = 13 vs CD 10"
      refute msg =~ "JoaT"
    end

    test "bardo con el skill entrenado → prof completa, no +mitad" do
      w = world([bard(level: 2)])

      # persuasion está en la ficha: 1d20(10) + CAR 3 + prof 2 = 15
      assert {:ok, msg, _} = Actions.check(w, "Lira", "persuasion", 15, false, always(10))

      assert msg =~ "chequeo de Persuasión (CAR)"
      assert msg =~ "1d20(10) + CAR 3 + prof 2 = 15 vs CD 15 — éxito"
      refute msg =~ "JoaT"
    end

    test "normalización: Animal Handling / animal-handling → animal_handling (SAB)" do
      w = world([rogue()])

      for input <- ["Animal Handling", "animal-handling", "ANIMAL HANDLING"] do
        assert {:ok, msg, _} = Actions.check(w, "Vex", input, 20, false, always(20))
        assert msg =~ "chequeo de Trato con animales (SAB)"
      end
    end

    test "skill desconocido → error directivo con ejemplos" do
      w = world([rogue()])

      assert {:error, msg} = Actions.check(w, "Vex", "cooking", 10, false, always(10))
      assert msg =~ "desconocidos: \"cooking\""
      assert msg =~ "stealth"
      assert msg =~ "str/dex/con/int/wis/cha"
    end

    test "característica cruda sigue funcionando (compat hacia atrás)" do
      w = world([rogue()])

      assert {:ok, msg, _} = Actions.check(w, "Vex", :dex, 15, false, always(11))
      assert msg =~ "chequeo de Destreza: d20 11 + +3 (dex) = 14 vs CD 15 — fallo"

      # String crudo (como llega de la tool)
      assert {:ok, msg2, _} = Actions.check(w, "Vex", "str", 10, false, always(10))
      assert msg2 =~ "chequeo de Fuerza: d20 10 = 10 vs CD 10 — éxito"
    end

    test "característica cruda de un bardo L2+ recibe JoaT (RAW: todo check sin prof)" do
      w = world([bard(level: 2)])

      assert {:ok, msg, _} = Actions.check(w, "Lira", "str", 10, false, always(10))

      # FUE -1 (str 8): 10 + -1 + 1 = 10
      assert msg =~ "d20 10 + -1 (str) + 1 (JoaT) = 10 vs CD 10 — éxito"
    end

    test "skill con ventaja mantiene el mode_tag" do
      w = world([rogue()])

      assert {:ok, msg, _} = Actions.check(w, "Vex", "stealth", 15, false, always(11), :advantage)

      assert msg =~ "chequeo de Sigilo (DES) (ventaja)"
    end

    test "inspiración bárdica se suma y aparece en el desglose del skill" do
      # Bardo L2 inspirado, skill sin entrenar: 1d20(5) + JoaT 1 + 1d6(4) inspiración
      w = world([bard(level: 2, inspired: true)])

      Process.put(:rolls, [5, 4])

      seq = fn _sides ->
        [h | t] = Process.get(:rolls)
        Process.put(:rolls, t)
        h
      end

      assert {:ok, msg, change} = Actions.check(w, "Lira", "deception", 9, false, seq)
      assert msg =~ "1d20(5) + CAR 3 + JoaT 1 + inspiración 4 = 13 vs CD 9"

      {:ok, w2} = change.(w)
      refute w2.characters["Lira"].inspired
    end
  end

  describe "Tools.ability_check — guards PC self / DM" do
    # Round-robin hands the floor to the FIRST participant, so each session is
    # built with the acting participant first.
    defp session_with_turn(participants) do
      game =
        start_session(
          world: world([rogue(), bard(level: 1), goblin()]),
          policy: :round_robin,
          participants: participants
        )

      assert {:ok, _first} = Session.start(game)
      game
    end

    test "PC tira su propio skill" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: always(11)}}

      assert {:ok, msg} = Tools.ability_check(ctx, "Vex", "stealth", 15, "normal")
      assert msg =~ "Vex hace un chequeo de Sigilo (DES)"
      assert msg =~ "prof 2"
    end

    test "PC NO puede tirar por otro (assert_controls)" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: always(11)}}

      assert {:error, msg} = Tools.ability_check(ctx, "Lira", "stealth", 15, "normal")
      assert msg =~ "RECHAZADO"
    end

    test "DM tira el skill de un personaje que controla (monstruo)" do
      game = session_with_turn([p("dm"), p("Vex"), p("Lira")])
      ctx = %{deps: %{state: SharedState.new(game, "dm"), roller: always(11)}}

      assert {:ok, msg} = Tools.ability_check(ctx, "goblin", "stealth", 12, "normal")
      assert msg =~ "goblin hace un chequeo de Sigilo (DES)"
      refute msg =~ "prof"
      refute msg =~ "JoaT"
    end

    test "skill desconocido desde la tool → error con ejemplos" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: always(11)}}

      assert {:error, msg} = Tools.ability_check(ctx, "Vex", "basketweaving", 10, "normal")
      assert msg =~ "desconocidos"
      assert msg =~ "stealth"
    end

    test "modo omitido (nil) → normal" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: always(11)}}

      assert {:ok, msg} = Tools.ability_check(ctx, "Vex", "athletics", 11, nil)
      assert msg =~ "chequeo de Atletismo (FUE)"
      refute msg =~ "ventaja"
    end
  end
end
