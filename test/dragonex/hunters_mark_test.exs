defmodule Dragonex.HuntersMarkTest do
  @moduledoc """
  Hunter's Mark 5e del explorador (D55 / M39): ranger L2+ gasta 1 casilla
  de nivel 1 y concentra; el motor suma +1d6 por impacto de arma contra la
  presa (crítico dobla los d6). Sin economía de acción bonus, ventajas de
  tracking, múltiples presas, transferir marca, Branding Smite, feats ni
  multiclase.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, PCAgent, RollLog, Text, Tools, Weapon, World}
  alias ExAgent.{Session, Session.SharedState}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp longsword do
    %Weapon{
      name: "longsword",
      dice: "1d8",
      damage_type: "slashing",
      attack_ability: :str
    }
  end

  defp ranger(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Ari",
          class: "ranger",
          level: 2,
          hp: 18,
          max_hp: 18,
          ac: 15,
          str: 16,
          dex: 14,
          con: 12,
          wis: 14,
          side: "pc",
          weapons: [longsword()]
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
          hp: 30,
          max_hp: 30,
          ac: 12,
          side: "enemy"
        ],
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

  # Mundo con la marca ya fijada (como si hunters_mark hubiera aplicado):
  # ranger L2 (2 casillas nivel 1) concentrando en "goblin".
  defp marked_world(opts \\ []) do
    {:ok, w} =
      World.set_concentration("Ari", "hunter's mark:goblin").(world([ranger(opts), goblin()]))

    w
  end

  describe "Actions.hunters_mark" do
    test "L2 marca: gasta 1 casilla nivel 1 y concentra en la presa (mensaje ES)" do
      w = world([ranger([]), goblin()])

      assert {:ok, msg, change} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg ==
               "Ari marca a goblin como presa (Hunter's Mark, concentración, casilla nivel 1 gastada)."

      {:ok, w2} = change.(w)
      assert w2.characters["Ari"].concentrating == "hunter's mark:goblin"
      assert w2.spell_slots["Ari"][1] == 1
    end

    test "sin casillas nivel 1 → error; no toca concentración" do
      w = world([ranger([]), goblin()])

      # Marca dos veces (con drop entre medias): 2 → 1 → 0 casillas.
      {:ok, _, change} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))
      {:ok, w} = change.(w)
      {:ok, w} = World.clear_concentration("Ari").(w)
      assert w.spell_slots["Ari"][1] == 1

      {:ok, _, change} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))
      {:ok, w} = change.(w)
      {:ok, w} = World.clear_concentration("Ari").(w)
      assert w.spell_slots["Ari"][1] == 0

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg =~ "casillas de hechizo de nivel 1"
      assert w.characters["Ari"].concentrating == nil
      assert w.spell_slots["Ari"][1] == 0
    end

    test "ya concentrando (otra marca u otro hechizo) → error; no gasta" do
      w = world([ranger([]), goblin()])
      {:ok, w} = World.set_concentration("Ari", "bless").(w)

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg =~ "ya concentra en bless"
      assert msg =~ "drop_concentration"
      assert w.spell_slots["Ari"][1] == 2
      assert w.characters["Ari"].concentrating == "bless"
    end

    test "no ranger → error; no gasta" do
      w = world([%{ranger([]) | class: "fighter"}, goblin()])

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg =~ "no es explorador"
    end

    test "ranger L1 → error (nivel 2)" do
      w = world([ranger(level: 1), goblin()])

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg =~ "nivel 2"
    end

    test "who/target inexistentes → error" do
      w = world([ranger([]), goblin()])

      assert {:error, msg} = Actions.hunters_mark(w, "ghost", "goblin", seq([]))
      assert msg =~ "no existe el personaje"

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "ghost", seq([]))
      assert msg =~ "no existe el objetivo"
    end

    test "who caído → error; no gasta" do
      w = world([ranger(hp: 0), goblin()])

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg =~ "caído"
      assert w.spell_slots["Ari"][1] == 2
    end

    test "target caído → error; no gasta" do
      w = world([ranger([]), goblin(hp: 0)])

      assert {:error, msg} = Actions.hunters_mark(w, "Ari", "goblin", seq([]))

      assert msg =~ "caído (0 pg) y no puede ser presa"
      assert w.spell_slots["Ari"][1] == 2
    end
  end

  describe "daño de la marca en make_attack" do
    test "el hit vs presa suma 1d6 con el tipo del arma" do
      w = marked_world()

      # prof 2 + str 3 = +5; d20 10 → 15 vs CA 12: hit. d8 4 + 3 = 7; marca d6 3.
      assert {:ok, msg, change} = Actions.attack(w, "Ari", "goblin", "longsword", seq([10, 4, 3]))

      assert msg =~ "acierta"
      assert msg =~ "por 10 de daño cortante en total (incluye 3 presa marcada)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 10
      assert w2.characters["Ari"].concentrating == "hunter's mark:goblin"
    end

    test "vs otro objetivo no suma (match exacto, sin fuzzy)" do
      w = world([ranger([]), goblin(), goblin(name: "goblin chief")])
      {:ok, w} = World.set_concentration("Ari", "hunter's mark:goblin").(w)

      assert {:ok, msg, change} =
               Actions.attack(w, "Ari", "goblin chief", "longsword", seq([10, 4, 99]))

      refute msg =~ "presa marcada"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin chief"].hp == 30 - 7
      assert Process.get(:seq) == [99]
    end

    test "match case-insensitive del nombre de la presa" do
      w = world([ranger([]), goblin()])
      {:ok, w} = World.set_concentration("Ari", "Hunter's Mark:GOBLIN").(w)

      assert {:ok, msg, _} = Actions.attack(w, "Ari", "goblin", "longsword", seq([10, 4, 3]))

      assert msg =~ "(incluye 3 presa marcada)"
    end

    test "crítico dobla los d6 de la marca" do
      w = marked_world()

      # d20 20 → crit: 2d8 (4+4) + str 3 = 11; marca 2d6 (2+3) = 5.
      assert {:ok, msg, change} =
               Actions.attack(w, "Ari", "goblin", "longsword", seq([20, 4, 4, 2, 3]))

      assert msg =~ "CRÍTICO"
      assert msg =~ "(incluye 5 presa marcada)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 16
    end

    test "la marca aplica a CADA impacto (L5 Extra Attack, 2 golpes)" do
      w = marked_world(level: 5)

      # L5: prof 3 + str 3 = +6; d20 10 → 16 vs CA 12: hit x2.
      # Cada golpe: d8 3 + 3 = 6; marca d6 2 → 8 por golpe.
      assert {:ok, msg, change} =
               Actions.attack(w, "Ari", "goblin", "longsword", seq([10, 3, 2, 10, 3, 2]))

      assert msg =~ "2 golpes"
      assert msg =~ "(incluye 2 presa marcada)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 16
    end

    test "el d6 de la marca entra al RollLog (patrón sneak)" do
      {:ok, rec} = RollLog.start()
      log = %RollLog{base: seq([10, 4, 3]), recorder: rec}
      w = marked_world()

      assert {:ok, _, _} =
               Actions.attack(w, "Ari", "goblin", "longsword", fixed_roller(1), :normal, log)

      entries = RollLog.entries(rec)
      dmg_entry = Enum.find(entries, &(&1.kind == :damage))
      assert dmg_entry.total == 10
      assert [6, 3] in dmg_entry.dice

      RollLog.stop(rec)
    end

    test "drop_concentration quita el bonus" do
      w = marked_world()
      {:ok, w} = World.clear_concentration("Ari").(w)

      assert {:ok, msg, change} =
               Actions.attack(w, "Ari", "goblin", "longsword", seq([10, 4, 99]))

      refute msg =~ "presa marcada"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 7
      assert Process.get(:seq) == [99]
    end

    test "una condición que rompe concentración quita el bonus" do
      w = marked_world()
      {:ok, w} = World.apply_condition("Ari", "stunned").(w)
      assert w.characters["Ari"].concentrating == nil

      assert {:error, _} = Actions.attack(w, "Ari", "goblin", "longsword", seq([99]))
      assert Process.get(:seq) == [99]
      {:ok, w} = World.remove_condition("Ari", "stunned").(w)

      assert {:ok, msg, _} = Actions.attack(w, "Ari", "goblin", "longsword", seq([10, 4, 99]))

      refute msg =~ "presa marcada"
      assert Process.get(:seq) == [99]
    end

    test "concentrar otro hechizo distinto no aplica marca" do
      w = world([ranger([]), goblin()])
      {:ok, w} = World.set_concentration("Ari", "bless").(w)

      assert {:ok, msg, _} = Actions.attack(w, "Ari", "goblin", "longsword", seq([10, 4, 99]))

      refute msg =~ "presa marcada"
      assert Process.get(:seq) == [99]
    end
  end

  describe "Codec" do
    test "la marca (string de concentración) sobrevive el roundtrip" do
      w = marked_world()

      assert Codec.decode(Codec.encode(w)).characters["Ari"].concentrating ==
               "hunter's mark:goblin"
    end
  end

  describe "Tools.hunters_mark" do
    setup do
      ari = ranger([])
      g = goblin()

      game =
        start_session(
          world:
            World.new(characters: %{"Ari" => ari, "goblin" => g}) |> World.init_spell_slots(),
          policy: :round_robin,
          participants: [p("dm"), p("Ari")]
        )

      assert {:ok, "dm"} = Session.start(game)
      %{game: game}
    end

    test "PC otro error", %{game: game} do
      ctx = %{deps: %{state: SharedState.new(game, "Ari"), roller: seq([])}}

      assert {:error, msg} = Tools.hunters_mark(ctx, "goblin", "goblin")

      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["goblin"].concentrating == nil
    end

    test "DM cualquiera; PC sí mismo", %{game: game} do
      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: seq([])}}

      assert {:ok, msg} = Tools.hunters_mark(dm, "Ari", "goblin")

      assert msg =~ "marca a goblin como presa"
      assert Session.read_state(game).characters["Ari"].concentrating == "hunter's mark:goblin"
      assert Session.read_state(game).spell_slots["Ari"][1] == 1

      # Turno del PC: concentrando ya no puede re-marcar; suelta y vuelve
      # a marcar (última casilla).
      assert {:ok, _} = Session.end_turn(game, "dm")
      pc = %{deps: %{state: SharedState.new(game, "Ari"), roller: seq([])}}

      assert {:error, msg} = Tools.hunters_mark(pc, "Ari", "goblin")
      assert msg =~ "ya concentra"

      assert {:ok, _} = Tools.drop_concentration(pc, "Ari")
      assert {:ok, _} = Tools.hunters_mark(pc, "Ari", "goblin")
      assert Session.read_state(game).spell_slots["Ari"][1] == 0
      assert Session.read_state(game).characters["Ari"].concentrating == "hunter's mark:goblin"
    end
  end

  describe "agentes" do
    test "PCAgent expone la tool y la línea de combate si ranger L2+ con casillas" do
      names = PCAgent.tools() |> Enum.map(&to_string(&1.name))
      assert "hunters_mark" in names

      ari = ranger([])
      g = goblin()

      combat =
        World.new(phase: :combat, characters: %{"Ari" => ari, "goblin" => g})
        |> World.init_spell_slots()

      assert PCAgent.instruction("Ari", ari, combat) =~ "hunters_mark"

      spent = %{combat | spell_slots: %{"Ari" => %{1 => 0}}}
      refute PCAgent.instruction("Ari", ari, spent) =~ "hunters_mark"

      l1 = ranger(level: 1)

      combat_l1 =
        World.new(phase: :combat, characters: %{"Ari" => l1, "goblin" => g})
        |> World.init_spell_slots()

      refute PCAgent.instruction("Ari", l1, combat_l1) =~ "hunters_mark"
    end

    test "DM prompt menciona la tool" do
      assert Dragonex.DM.system_prompt() =~ "hunters_mark"
    end

    test "Text.scrub elimina hunters_mark narrado en prosa" do
      text = "Ari usa hunters_mark(\"Ari\", \"goblin\") y sonríe a su presa."
      refute Text.scrub(text) =~ "hunters_mark"
    end
  end
end
