defmodule Dragonex.ExpertiseTest do
  @moduledoc """
  Expertise 5e de pícaro y bardo (D73 / M57): duplica el bonus de
  competencia en los checks de skills entrenadas elegidas. Se modela como
  TOOL elegida una vez (`gain_expertise`, validada por el motor: clase,
  nivel, entrenamiento, duplicado y cupo por clase/nivel en
  `Progression.expertise_count/2`) — mismo patrón que todas las features
  del motor: el LLM decide, el motor valida y persiste. La resolución
  (×2 en vez de ×1) vive en `Combat.check_proficiency/3` y la consumen
  `Actions.check` y `cunning_action_hide`; JoaT (D60) nunca aplica a una
  expertised (ya es competente). Sin Expertise en tools/instrumentos,
  picks extra 2024, integración con level-up, feats ni multiclase.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Tools, World}
  alias Dragonex.Heroes.Progression
  alias Dragonex.Rules.Combat
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
          skill_proficiencies: ["stealth", "acrobatics", "persuasion"],
          weapons: []
        ],
        opts
      )
    )
  end

  defp bard(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Lira",
          class: "bard",
          level: 3,
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
          skill_proficiencies: ["persuasion", "performance"],
          weapons: []
        ],
        opts
      )
    )
  end

  defp fighter(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 16,
          side: "pc",
          skill_proficiencies: ["athletics"],
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

  # Aplica N elecciones exitosas seguidas sobre el mismo mundo.
  defp gain!(world, who, skills) do
    Enum.reduce_while(skills, {:ok, world}, fn skill, {:ok, w} ->
      case Actions.gain_expertise(w, who, skill) do
        {:ok, _msg, change} ->
          {:ok, w2} = change.(w)
          {:cont, {:ok, w2}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  describe "Progression.expertise_count/2 — tabla de cupos" do
    test "rogue: 2 desde L1, 4 desde L6" do
      assert Progression.expertise_count("rogue", 1) == 2
      assert Progression.expertise_count("rogue", 5) == 2
      assert Progression.expertise_count("rogue", 6) == 4
      assert Progression.expertise_count("rogue", 20) == 4
    end

    test "bard: 0 antes de L3, 2 en L3, 4 desde L10" do
      assert Progression.expertise_count("bard", 1) == 0
      assert Progression.expertise_count("bard", 2) == 0
      assert Progression.expertise_count("bard", 3) == 2
      assert Progression.expertise_count("bard", 9) == 2
      assert Progression.expertise_count("bard", 10) == 4
      assert Progression.expertise_count("bard", 20) == 4
    end

    test "demás clases → 0" do
      for c <- ["fighter", "wizard", "cleric", "monster", nil] do
        assert Progression.expertise_count(c, 20) == 0
      end
    end
  end

  describe "Actions.gain_expertise/3 — validación del motor" do
    test "pícaro L1 elige 2; la 3ª → error de cupo" do
      w = world([rogue()])

      assert {:ok, msg1, c1} = Actions.gain_expertise(w, "Vex", "stealth")
      assert msg1 == "Vex profundiza su dominio de Sigilo (Expertise 1/2)."
      {:ok, w} = c1.(w)

      assert {:ok, msg2, c2} = Actions.gain_expertise(w, "Vex", "acrobatics")
      assert msg2 == "Vex profundiza su dominio de Acróbata (Expertise 2/2)."
      {:ok, w} = c2.(w)

      assert w.characters["Vex"].expertise == ["stealth", "acrobatics"]

      assert {:error, reason} = Actions.gain_expertise(w, "Vex", "persuasion")
      assert reason =~ "Vex ya ha elegido sus 2 expertises"
      assert reason =~ "Sigilo, Acróbata"
    end

    test "pícaro L6 permite 2 más (4 total)" do
      w =
        world([
          rogue(
            level: 6,
            skill_proficiencies: ["stealth", "acrobatics", "persuasion", "insight", "deception"]
          )
        ])

      assert {:ok, w2} = gain!(w, "Vex", ["stealth", "acrobatics", "persuasion", "insight"])

      assert w2.characters["Vex"].expertise == ["stealth", "acrobatics", "persuasion", "insight"]

      # La 5ª entrenada ya no cabe: cupo 4 agotado (mensaje con el cupo actual).
      assert {:error, reason} = Actions.gain_expertise(w2, "Vex", "deception")
      assert reason =~ "ya ha elegido sus 4 expertises"
      assert reason =~ "Sigilo, Acróbata, Persuasión, Perspicacia"
    end

    test "bardo L3 elige 2; bardo L10 llega a 4" do
      w = world([bard(level: 3)])

      assert {:ok, w2} = gain!(w, "Lira", ["persuasion", "performance"])
      assert w2.characters["Lira"].expertise == ["persuasion", "performance"]
      assert {:error, reason} = Actions.gain_expertise(w2, "Lira", "deception")
      assert reason =~ "no tiene competencia en Engaño"

      w10 =
        world([
          bard(
            level: 10,
            skill_proficiencies: ["persuasion", "performance", "deception", "insight"]
          )
        ])

      assert {:ok, w11} =
               gain!(w10, "Lira", ["persuasion", "performance", "deception", "insight"])

      assert length(w11.characters["Lira"].expertise) == 4
    end

    test "bardo L1–2 → error de nivel (llega a nivel 3)" do
      for level <- [1, 2] do
        assert {:error, reason} =
                 Actions.gain_expertise(world([bard(level: level)]), "Lira", "persuasion")

        assert reason =~ "aún no tiene Expertise (llega a nivel 3)"
      end
    end

    test "clase sin Expertise → error (sólo pícaros y bardos)" do
      assert {:error, reason} =
               Actions.gain_expertise(world([fighter()]), "Thane", "athletics")

      assert reason =~ "sólo pícaros y bardos"
    end

    test "who inexistente / caído → error sin mutar" do
      assert {:error, reason} = Actions.gain_expertise(world([rogue()]), "Nadie", "stealth")
      assert reason =~ "no existe el personaje: Nadie"

      w = world([rogue(hp: 0)])

      assert {:error, reason} = Actions.gain_expertise(w, "Vex", "stealth")
      assert reason =~ "está caído (0 pg)"
      assert w.characters["Vex"].expertise == []
    end

    test "skill desconocida → error directivo con ejemplos" do
      assert {:error, reason} = Actions.gain_expertise(world([rogue()]), "Vex", "cooking")
      assert reason =~ ~s(skill desconocida: "cooking")
      assert reason =~ "stealth"
    end

    test "skill sin competencia → error" do
      w = world([rogue()])

      assert {:error, reason} = Actions.gain_expertise(w, "Vex", "insight")
      assert reason =~ "Vex no tiene competencia en Perspicacia"
      assert reason =~ "skills entrenadas"
      assert w.characters["Vex"].expertise == []
    end

    test "skill duplicada → error" do
      assert {:ok, w} = gain!(world([rogue()]), "Vex", ["stealth"])

      assert {:error, reason} = Actions.gain_expertise(w, "Vex", "stealth")
      assert reason =~ "ya tiene Expertise en Sigilo"
    end

    test "normalización del nombre: Stealth / STEALTH → stealth canónico" do
      assert {:ok, w} = gain!(world([rogue()]), "Vex", ["Stealth"])
      assert w.characters["Vex"].expertise == ["stealth"]

      # Duplicado detectado aunque llegue con otro formato.
      assert {:error, reason} = Actions.gain_expertise(w, "Vex", "STEALTH")
      assert reason =~ "ya tiene Expertise"
    end
  end

  describe "Resolución — doble competencia en checks" do
    test "check con expertise = 2×prof y etiqueta (experto)" do
      # Pícaro L1 (prof 2) con stealth entrenada + expertise: 11 + 3 + 4 = 18.
      assert {:ok, w} = gain!(world([rogue()]), "Vex", ["stealth"])

      assert {:ok, msg, _} = Actions.check(w, "Vex", "stealth", 15, false, always(11))
      assert msg =~ "chequeo de Sigilo (DES)"
      assert msg =~ "1d20(11) + DES 3 + prof 4 (experto) = 18 vs CD 15 — éxito"
    end

    test "sin expertise → prof normal (regresión D60)" do
      w = world([rogue()])

      assert {:ok, msg, _} = Actions.check(w, "Vex", "stealth", 15, false, always(11))
      assert msg =~ "1d20(11) + DES 3 + prof 2 = 16 vs CD 15 — éxito"
      refute msg =~ "experto"
    end

    test "expertise escala con la prof (L9 → 2×4 = 8)" do
      assert {:ok, w} = gain!(world([rogue(level: 9)]), "Vex", ["stealth"])

      assert {:ok, msg, _} = Actions.check(w, "Vex", "stealth", 20, false, always(11))
      assert msg =~ "prof 8 (experto)"
    end

    test "JoaT no interfiere: bardo L5 entrenado+expertise → 2×prof, sin +1 extra" do
      # Bardo L5 (prof 3): 1d20(10) + CAR 3 + prof 6 (experto) = 19.
      assert {:ok, w} = gain!(world([bard(level: 5)]), "Lira", ["persuasion"])

      assert {:ok, msg, _} = Actions.check(w, "Lira", "persuasion", 18, false, always(10))
      assert msg =~ "1d20(10) + CAR 3 + prof 6 (experto) = 19 vs CD 18 — éxito"
      refute msg =~ "JoaT"
    end

    test "bardo L5 con skill SIN entrenar sigue en JoaT (D60 intacto)" do
      w = world([bard(level: 5)])

      assert {:ok, msg, _} = Actions.check(w, "Lira", "deception", 12, false, always(10))
      assert msg =~ "+ CAR 3 + JoaT 1"
      refute msg =~ "experto"
    end

    test "ability cruda sin skill nombrada NUNCA dobla" do
      assert {:ok, w} = gain!(world([rogue()]), "Vex", ["stealth"])

      assert {:ok, msg, _} = Actions.check(w, "Vex", :dex, 15, false, always(11))
      assert msg =~ "chequeo de Destreza: d20 11 + +3 (dex) = 14 vs CD 15 — fallo"
      refute msg =~ "experto"
      refute msg =~ "competencia"

      assert {:ok, msg2, _} = Actions.check(w, "Vex", "dex", 15, true, always(11))
      # Ability cruda conserva el flag del caller (prof ×1, nunca ×2).
      assert msg2 =~ "2 (competencia)"
      refute msg2 =~ "experto"
    end

    test "otra skill entrenada sin expertise no dobla" do
      assert {:ok, w} = gain!(world([rogue()]), "Vex", ["stealth"])

      assert {:ok, msg, _} = Actions.check(w, "Vex", "acrobatics", 15, false, always(11))
      assert msg =~ "prof 2 = 16"
      refute msg =~ "experto"
    end
  end

  describe "Combat.check_proficiency/3" do
    test "entrenado + expertised → {2×prof, :expert}" do
      assert {4, :expert} =
               Combat.check_proficiency(rogue(expertise: ["stealth"]), true, "stealth")

      assert {8, :expert} =
               Combat.check_proficiency(rogue(level: 9, expertise: ["stealth"]), true, "stealth")
    end

    test "skill nil o no expertised → comportamientos D60 intactos" do
      assert {2, :prof} = Combat.check_proficiency(rogue(expertise: ["stealth"]), true, nil)

      assert {2, :prof} =
               Combat.check_proficiency(rogue(expertise: ["stealth"]), true, "acrobatics")

      # Expertise sin entrenamiento (dato inconsistente) no dobla.
      assert {0, :none} =
               Combat.check_proficiency(rogue(expertise: ["stealth"]), false, "stealth")

      assert {1, :joat} =
               Combat.check_proficiency(bard(level: 2, expertise: ["stealth"]), false, "stealth")
    end
  end

  describe "cunning_action_hide — Sigilo doblado (D57 × D73)" do
    test "hide con stealth expertise dobla la prof" do
      # Pícaro L2 (prof 2), DES 16, goblin SAB 10 → CD 10.
      # 1d20(11) + 3 + 4 (experto) = 18 vs 10 — oculto.
      assert {:ok, w} = gain!(world([rogue(level: 2)]), "Vex", ["stealth"])

      assert {:ok, msg, change} = Actions.cunning_action_hide(w, "Vex", always(11))
      assert msg =~ "1d20(11)+3+4 (experto)=18 vs 10 — oculto"

      {:ok, w2} = change.(w)
      assert "hidden" in Character.condition_names(w2.characters["Vex"])
    end

    test "hide sin expertise → prof ×1 (regresión)" do
      w = world([rogue(level: 2)])

      assert {:ok, msg, _} = Actions.cunning_action_hide(w, "Vex", always(11))
      assert msg =~ "1d20(11)+3+2=16 vs 10 — oculto"
      refute msg =~ "experto"
    end
  end

  describe "Codec — jsonb viejo/ausente → []" do
    test "encode/decode roundtrip del campo expertise" do
      c = rogue(expertise: ["stealth", "acrobatics"])
      encoded = Codec.encode_character(c)
      assert encoded["expertise"] == ["stealth", "acrobatics"]

      assert Codec.decode_character(encoded).expertise == ["stealth", "acrobatics"]
    end

    test "jsonb viejo sin clave expertise → []" do
      old = Codec.encode_character(rogue()) |> Map.drop(["expertise"])

      assert old["expertise"] == nil
      assert Codec.decode_character(old).expertise == []
    end

    test "mundo entero: expertise sobrevive encode → decode" do
      assert {:ok, w} = gain!(world([rogue()]), "Vex", ["stealth"])

      decoded = Codec.decode(Codec.encode(w))
      assert decoded.characters["Vex"].expertise == ["stealth"]
    end
  end

  describe "Tools.gain_expertise — guards PC self / DM" do
    defp session_with_turn(participants) do
      game =
        start_session(
          world: world([rogue(expertise: ["stealth"]), bard(), goblin()]),
          policy: :round_robin,
          participants: participants
        )

      assert {:ok, _first} = Session.start(game)
      game
    end

    test "PC elige su propio Expertise" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      state = SharedState.new(game, "Vex")
      ctx = %{deps: %{state: state, roller: always(11)}}

      assert {:ok, msg} = Tools.gain_expertise(ctx, "Vex", "acrobatics")
      assert msg == "Vex profundiza su dominio de Acróbata (Expertise 2/2)."

      w = SharedState.read(state)
      assert w.characters["Vex"].expertise == ["stealth", "acrobatics"]
    end

    test "PC NO puede elegir por otro (RECHAZADO)" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: always(11)}}

      assert {:error, msg} = Tools.gain_expertise(ctx, "Lira", "persuasion")
      assert msg =~ "RECHAZADO"
    end

    test "DM elige por cualquier personaje" do
      game = session_with_turn([p("dm"), p("Vex"), p("Lira")])
      ctx = %{deps: %{state: SharedState.new(game, "dm"), roller: always(11)}}

      assert {:ok, msg} = Tools.gain_expertise(ctx, "Lira", "persuasion")
      assert msg =~ "Lira profundiza su dominio de Persuasión (Expertise 1/2)."
    end

    test "error del motor no muta el world (cupo agotado desde la tool)" do
      game = session_with_turn([p("Vex"), p("Lira"), p("dm")])
      state = SharedState.new(game, "Vex")
      ctx = %{deps: %{state: state, roller: always(11)}}

      assert {:ok, msg} = Tools.gain_expertise(ctx, "Vex", "acrobatics")
      assert msg =~ "Expertise 2/2"

      assert {:error, reason} = Tools.gain_expertise(ctx, "Vex", "persuasion")
      assert reason =~ "ya ha elegido sus 2 expertises"

      # El error dejó el world intacto.
      assert SharedState.read(state).characters["Vex"].expertise == ["stealth", "acrobatics"]
    end
  end

  describe "PCAgent — línea condicional y allowlist" do
    test "pícaro L1 con cupo disponible ve la línea" do
      prompt = Dragonex.PCAgent.instruction("Vex", rogue(), world([rogue(), goblin()]))
      assert prompt =~ "gain_expertise"
      assert prompt =~ "elecciones pendientes 0/2"
    end

    test "pícaro con cupo lleno NO ve la línea" do
      c = rogue(expertise: ["stealth", "acrobatics"])
      prompt = Dragonex.PCAgent.instruction("Vex", c, world([c, goblin()]))
      refute prompt =~ "gain_expertise"
    end

    test "bardo L1–2 NO ve la línea; L3 sí" do
      bard2 = bard(level: 2)
      refute Dragonex.PCAgent.instruction("Lira", bard2, world([bard2])) =~ "gain_expertise"

      prompt = Dragonex.PCAgent.instruction("Lira", bard(), world([bard()]))
      assert prompt =~ "gain_expertise"
      assert prompt =~ "elecciones pendientes 0/2"
    end

    test "otras clases NO ven la línea" do
      refute Dragonex.PCAgent.instruction("Thane", fighter(), world([fighter()])) =~
               "gain_expertise"
    end

    test "la tool está en el set del PCAgent" do
      names = Dragonex.PCAgent.tools() |> Enum.map(&to_string(&1.name))
      assert "gain_expertise" in names
    end
  end
end
