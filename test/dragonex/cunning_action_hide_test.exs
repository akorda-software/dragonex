defmodule Dragonex.CunningActionHideTest do
  @moduledoc """
  Cunning Action: Hide 5e del pícaro (D57 / M41): rogue L2+ tira Sigilo
  (1d20 + DES + prof si entrenado) contra la percepción pasiva más alta de
  los enemigos conscientes (DC 10 sin enemigos). Éxito → condición "hidden"
  → ventaja en make_attack (que habilita Sneak Attack D41) y el ataque lo
  revela. Sin Dash/Disengage (sin grid ni ataques de oportunidad),
  visibilidad/posición, sigilo sostenido, Uncanny Dodge, feats ni
  multiclase.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, PCAgent, RollLog, Spell, Text, Tools, Weapon, World}
  alias ExAgent.{Session, Session.SharedState}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp dagger do
    %Weapon{
      name: "dagger",
      dice: "1d4",
      damage_type: "piercing",
      attack_ability: :dex,
      finesse: true
    }
  end

  defp rogue(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Vex",
          class: "rogue",
          level: 2,
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
          weapons: [dagger()]
        ],
        opts
      )
    )
  end

  # Enemigo sabio: SAB 16 (+3) + percepción entrenada (prof 2) → pasiva 15.
  defp guard(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "guard",
          class: "monster",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 14,
          str: 10,
          dex: 10,
          con: 10,
          int: 10,
          wis: 16,
          cha: 10,
          side: "enemy",
          skill_proficiencies: ["perception"]
        ],
        opts
      )
    )
  end

  # Enemigo tonto: SAB 10 sin entrenar → pasiva 10.
  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "goblin",
          class: "monster",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 12,
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

  # Mundo con Vex ya oculto (como si cunning_action_hide hubiera triunfado).
  defp hidden_world(opts \\ []) do
    {:ok, w} = World.apply_condition("Vex", "hidden").(world([rogue(opts), goblin()]))
    w
  end

  describe "Actions.cunning_action_hide — éxito/fallo" do
    test "L2 con sigilo entrenado esconde: 1d20+DES+prof vs pasiva máxima (mensaje ES)" do
      w = world([rogue(), goblin(), guard()])

      # DC = max(pasiva goblin 10, pasiva guard 15) = 15.
      # d20 12 + DES 3 + prof 2 = 17 vs 15 → oculto.
      assert {:ok, msg, change} = Actions.cunning_action_hide(w, "Vex", seq([12]))

      assert msg == "Vex se esconde: 1d20(12)+3+2=17 vs 15 — oculto"

      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Vex", "hidden")
    end

    test "falla con roller bajo: sin condición, mensaje de fallo" do
      w = world([rogue(), goblin(), guard()])

      # 5 + 3 + 2 = 10 vs 15 → falla.
      assert {:ok, msg, change} = Actions.cunning_action_hide(w, "Vex", seq([5]))

      assert msg == "Vex se esconde: 1d20(5)+3+2=10 vs 15 — falla y sigue a la vista"

      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Vex", "hidden")
    end

    test "sin sigilo entrenado no suma prof" do
      w = world([rogue(skill_proficiencies: []), goblin()])

      # DC 10; d20 6 + 3 = 9 vs 10 → falla (con prof habría sido 11).
      assert {:ok, msg, _} = Actions.cunning_action_hide(w, "Vex", seq([6]))

      assert msg == "Vex se esconde: 1d20(6)+3=9 vs 10 — falla y sigue a la vista"
    end
  end

  describe "DC" do
    test "usa la pasiva del enemigo más perceptivo (el sabio, no el tonto)" do
      w = world([rogue(), goblin(), guard()])

      # 8 + 3 + 2 = 13: supera al tonto (10) pero no al sabio (15) → falla.
      assert {:ok, msg, _} = Actions.cunning_action_hide(w, "Vex", seq([8]))

      assert msg =~ "vs 15 — falla"
    end

    test "sin enemigos conscientes → CD 10 (mínimo RAW)" do
      w = world([rogue(), goblin(hp: 0), guard(hp: 0)])

      # 5 + 3 + 2 = 10 vs 10 → éxito justo.
      assert {:ok, msg, change} = Actions.cunning_action_hide(w, "Vex", seq([5]))

      assert msg =~ "vs 10 — oculto"

      {:ok, w2} = change.(w)
      assert World.has_condition?(w2, "Vex", "hidden")
    end

    test "ignora aliados y enemigos caídos al computar la pasiva máxima" do
      ally =
        Character.new(
          name: "Thane",
          class: "fighter",
          hp: 20,
          max_hp: 20,
          side: "pc",
          wis: 20,
          skill_proficiencies: ["perception"]
        )

      w = world([rogue(), ally, goblin(), guard(hp: 0)])

      # Solo queda el tonto (pasiva 10): 6 + 3 + 2 = 11 vs 10 → oculto.
      assert {:ok, msg, _} = Actions.cunning_action_hide(w, "Vex", seq([6]))

      assert msg =~ "vs 10 — oculto"
    end

    test "passive_perception/1: 10 + SAB + prof si percepción entrenada" do
      assert Actions.passive_perception(guard()) == 15
      assert Actions.passive_perception(goblin()) == 10
    end
  end

  describe "ventaja de hidden en make_attack" do
    test "el ataque del oculto tira 2 dados y keep-high (ventaja efectiva)" do
      w = hidden_world()

      # Ventaja: max(5, 15) = 15; +5 (prof 2 + DES 3) = 20 vs CA 12 → hit.
      # d4 4 + 3 = 7; sneak 1d6 6 → 13 total.
      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([5, 15, 4, 6]))

      assert msg =~ "d20 15"
      assert msg =~ "(ventaja)"
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20 - 13
    end

    test "hidden + arma finesse dispara Sneak Attack sin aliado (sinergia D41)" do
      w = hidden_world()

      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([10, 19, 3, 4]))

      assert msg =~ "+4 sneak"
      refute msg =~ "fallo"

      {:ok, w2} = change.(w)
      # d4 3 + 3 + sneak 4 = 10.
      assert w2.characters["goblin"].hp == 20 - 10
    end

    test "desventaja pedida + hidden → normal (cancelación 5e, un solo dado)" do
      w = hidden_world()

      # Un solo d20 (18) — la desventaja pedida cancela la ventaja de hidden.
      assert {:ok, msg, change} =
               Actions.attack(w, "Vex", "goblin", "dagger", seq([18, 4, 99]), :disadvantage)

      assert msg =~ "d20 18"
      refute msg =~ "ventaja"
      refute msg =~ "desventaja"
      # :normal sin aliado consciente → sin sneak (D41 exige ventaja o aliado).
      refute msg =~ "sneak"
      assert Process.get(:seq) == [99]

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20 - 7
    end
  end

  describe "limpieza de hidden" do
    test "make_attack con acierto revela al pícaro (hit o miss, todos los swings)" do
      w = hidden_world()

      # Ventaja max(15, 18) = 18 + 5 = 23 vs CA 12 → hit; d4 3 + 3 y sneak d6 6.
      assert {:ok, _, change} = Actions.attack(w, "Vex", "goblin", "dagger", seq([15, 18, 3, 6]))

      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Vex", "hidden")
    end

    test "make_attack con fallo también revela" do
      w = hidden_world()

      # Ventaja max(2, 3) = 3 + 5 = 8 vs CA 12 → fallo.
      assert {:ok, _, change} = Actions.attack(w, "Vex", "goblin", "dagger", seq([2, 3]))

      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Vex", "hidden")
    end

    test "hechizo de ataque del oculto: ventaja gratis por attack_mode y revela" do
      fire_bolt = %Spell{
        name: "fire bolt",
        level: 0,
        kind: :attack,
        casting_ability: :int,
        dice: "1d10",
        damage_type: "fire"
      }

      vex = %{rogue() | int: 16, spells: [fire_bolt]}
      w = world([vex, goblin()])
      {:ok, w} = World.apply_condition("Vex", "hidden").(w)

      # Ventaja max(4, 18) = 18 + 5 (prof 2 + INT 3) = 23 vs CA 12 → hit 1d10 7.
      assert {:ok, msg, change} =
               Actions.spell(w, "Vex", "fire bolt", "goblin", seq([4, 18, 7]))

      assert msg =~ "(ventaja)"
      assert msg =~ "23 vs CA 12"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 20 - 7
      refute World.has_condition?(w2, "Vex", "hidden")
    end

    test "un pícaro NO oculto no pierde nada (no-op de la limpieza)" do
      w = world([rogue(), goblin()])

      assert {:ok, _, change} = Actions.attack(w, "Vex", "goblin", "dagger", seq([15, 3]))

      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Vex", "hidden")
    end
  end

  describe "errores (no mutan)" do
    test "who inexistente → error" do
      w = world([rogue(), goblin()])

      assert {:error, msg} = Actions.cunning_action_hide(w, "ghost", seq([20]))
      assert msg =~ "no existe el personaje"
    end

    test "who caído (hp 0) → error" do
      w = world([rogue(hp: 0), goblin()])

      assert {:error, msg} = Actions.cunning_action_hide(w, "Vex", seq([20]))
      assert msg =~ "caído"
    end

    test "no rogue → error" do
      w = world([%{rogue() | class: "fighter"}, goblin()])

      assert {:error, msg} = Actions.cunning_action_hide(w, "Vex", seq([20]))
      assert msg =~ "no es pícaro"
    end

    test "rogue L1 → error (nivel 2)" do
      w = world([rogue(level: 1), goblin()])

      assert {:error, msg} = Actions.cunning_action_hide(w, "Vex", seq([20]))
      assert msg =~ "nivel 2"
    end

    test "ya oculto → error sin re-tirar" do
      w = hidden_world()

      assert {:error, msg} = Actions.cunning_action_hide(w, "Vex", seq([20]))
      assert msg =~ "ya está oculto"
      assert Process.get(:seq) == [20]
    end
  end

  describe "RollLog" do
    test "el chequeo entra al log con el patrón ability_check" do
      {:ok, rec} = RollLog.start()
      log = %RollLog{base: seq([12]), recorder: rec}
      w = world([rogue(), goblin(), guard()])

      assert {:ok, _, _} = Actions.cunning_action_hide(w, "Vex", fixed_roller(1), log)

      entries = RollLog.entries(rec)
      entry = Enum.find(entries, &(&1.kind == :check))

      assert entry.who == "Vex"
      assert entry.reason =~ "Sigilo"
      assert entry.total == 17
      assert entry.against == ["dc", 15]
      assert entry.outcome == :success
      assert entry.dice == [[20, 12]]

      RollLog.stop(rec)
    end
  end

  describe "Tools.cunning_action_hide" do
    setup do
      game =
        start_session(
          world: world([rogue(), goblin(), guard()]),
          policy: :round_robin,
          participants: [p("dm"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)
      %{game: game}
    end

    test "PC otro → RECHAZADO sin mutar", %{game: game} do
      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: seq([20])}}

      assert {:error, msg} = Tools.cunning_action_hide(ctx, "goblin")

      assert msg =~ "RECHAZADO"
      refute World.has_condition?(Session.read_state(game), "Vex", "hidden")
    end

    test "DM cualquiera; PC sí mismo; ya oculto → error", %{game: game} do
      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: seq([10])}}

      # 10 + 3 + 2 = 15 vs 15 → oculto.
      assert {:ok, msg} = Tools.cunning_action_hide(dm, "Vex")
      assert msg =~ "oculto"
      assert World.has_condition?(Session.read_state(game), "Vex", "hidden")

      assert {:ok, _} = Session.end_turn(game, "dm")
      pc = %{deps: %{state: SharedState.new(game, "Vex"), roller: seq([20])}}

      # Re-esconderse mientras oculto → error (no re-tira).
      assert {:error, msg2} = Tools.cunning_action_hide(pc, "Vex")
      assert msg2 =~ "ya está oculto"
    end

    test "errores del motor pasan por la tool sin mutar", %{game: game} do
      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: seq([20])}}

      assert {:error, msg} = Tools.cunning_action_hide(dm, "ghost")
      assert msg =~ "no existe el personaje"
    end
  end

  describe "agentes" do
    test "PCAgent expone la tool y la línea de combate si rogue L2+ no oculto" do
      names = PCAgent.tools() |> Enum.map(&to_string(&1.name))
      assert "cunning_action_hide" in names

      vex = rogue()
      g = goblin()
      combat = World.new(phase: :combat, characters: %{"Vex" => vex, "goblin" => g})

      assert PCAgent.instruction("Vex", vex, combat) =~ "cunning_action_hide"

      # Ya oculto → no se sugiere (re-esconderse es error).
      {:ok, combat_hidden} = World.apply_condition("Vex", "hidden").(combat)
      vex_hidden = combat_hidden.characters["Vex"]
      refute PCAgent.instruction("Vex", vex_hidden, combat_hidden) =~ "cunning_action_hide"

      # L1 → no hay Cunning Action.
      l1 = rogue(level: 1)
      combat_l1 = World.new(phase: :combat, characters: %{"Vex" => l1, "goblin" => g})
      refute PCAgent.instruction("Vex", l1, combat_l1) =~ "cunning_action_hide"
    end

    test "DM prompt menciona la tool" do
      assert Dragonex.DM.system_prompt() =~ "cunning_action_hide"
    end

    test "Text.scrub elimina cunning_action_hide narrado en prosa" do
      text = "Vex llama cunning_action_hide(\"Vex\") y se funde con las sombras."
      refute Text.scrub(text) =~ "cunning_action_hide"
    end
  end
end
