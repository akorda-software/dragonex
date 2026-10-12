defmodule Dragonex.FontOfMagicTest do
  @moduledoc """
  Font of Magic 5e (D56): hechicero L2+ convierte puntos de hechicería en
  casillas y al revés. Sin Metamagic, sorcerous restoration, casillas > 5º,
  gastar puntos en otras cosas, feats ni multiclase.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, PCAgent, Text, Tools, World}
  alias Dragonex.Heroes.Progression
  alias ExAgent.{Session, Session.SharedState}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp sorcerer(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Sylas",
          class: "sorcerer",
          level: 2,
          sorcery_points: 2,
          hp: 16,
          max_hp: 16,
          ac: 13,
          str: 9,
          dex: 14,
          con: 12,
          cha: 16,
          side: "pc"
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

  # Slots tracked like the real Game flow (init_spell_slots).
  defp world(chars) do
    chars
    |> Enum.reduce(World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  describe "Progression" do
    test "sorcery_points: hechicero L2+ → nivel; L1 y otras clases → 0" do
      assert Progression.sorcery_points("sorcerer", 2) == 2
      assert Progression.sorcery_points("sorcerer", 5) == 5
      assert Progression.sorcery_points("sorcerer", 20) == 20
      assert Progression.sorcery_points("sorcerer", 1) == 0
      assert Progression.sorcery_points("monk", 5) == 0
      assert Progression.sorcery_points("wizard", 20) == 0
    end

    test "sorcery_slot_cost: tabla RAW 1..5; fuera de rango → nil" do
      assert Progression.sorcery_slot_cost(1) == 2
      assert Progression.sorcery_slot_cost(2) == 3
      assert Progression.sorcery_slot_cost(3) == 5
      assert Progression.sorcery_slot_cost(4) == 6
      assert Progression.sorcery_slot_cost(5) == 7
      assert Progression.sorcery_slot_cost(0) == nil
      assert Progression.sorcery_slot_cost(6) == nil
      assert Progression.sorcery_slot_cost("2") == nil
    end
  end

  describe "Actions.create_spell_slot" do
    test "L2 con 2 puntos crea casilla L1: coste 2, quedan 0, casilla 1º +1" do
      w = world([sorcerer([])])

      # L2: 3 casillas de nivel 1 diarias; RAW permite superar el máximo.
      {:ok, msg, change} = Actions.create_spell_slot(w, "Sylas", 1)

      assert msg =~ "teje magia"
      assert msg =~ "convierte 2 puntos de hechicería en 1 casilla de nivel 1"
      assert msg =~ "quedan 0 puntos"
      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].sorcery_points == 0
      assert w2.spell_slots["Sylas"][1] == 4
    end

    test "L5 crea casilla L3 (coste 5) y puede encadenar varias" do
      w = world([sorcerer(level: 5, sorcery_points: 5)])

      {:ok, msg, change} = Actions.create_spell_slot(w, "Sylas", 3)

      assert msg =~ "1 casilla de nivel 3"
      assert msg =~ "quedan 0 puntos"
      {:ok, w2} = change.(w)
      assert w2.spell_slots["Sylas"][3] == 3
      assert w2.characters["Sylas"].sorcery_points == 0
    end

    test "puntos insuficientes → error sin mutar" do
      w = world([sorcerer(sorcery_points: 1)])

      assert {:error, msg} = Actions.create_spell_slot(w, "Sylas", 1)

      assert msg =~ "no tiene suficientes puntos de hechicería"
      assert msg =~ "le quedan 1"
      assert w.characters["Sylas"].sorcery_points == 1
      assert w.spell_slots["Sylas"][1] == 3
    end

    test "nivel de casilla 0/6/inválido → error" do
      w = world([sorcerer([])])

      assert {:error, msg0} = Actions.create_spell_slot(w, "Sylas", 0)
      assert msg0 =~ "nivel de casilla inválido"

      assert {:error, msg6} = Actions.create_spell_slot(w, "Sylas", 6)
      assert msg6 =~ "nivel de casilla inválido"

      assert {:error, msgx} = Actions.create_spell_slot(w, "Sylas", "2")
      assert msgx =~ "nivel de casilla inválido"
      assert w.characters["Sylas"].sorcery_points == 2
    end

    test "hechicero L1 → error (nivel 2)" do
      w = world([sorcerer(level: 1, sorcery_points: 0)])

      assert {:error, msg} = Actions.create_spell_slot(w, "Sylas", 1)

      assert msg =~ "nivel 2"
      assert w.characters["Sylas"].sorcery_points == 0
    end

    test "no hechicero → error; no gasta" do
      wizard =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 5,
          sorcery_points: 5,
          hp: 20,
          max_hp: 20,
          side: "pc"
        )

      w = world([wizard])

      assert {:error, msg} = Actions.create_spell_slot(w, "Lyra", 1)

      assert msg =~ "no es hechicero"
      assert w.characters["Lyra"].sorcery_points == 5
    end

    test "hechicero caído → error; who inexistente → error" do
      w = world([sorcerer(hp: 0)])

      assert {:error, msg} = Actions.create_spell_slot(w, "Sylas", 1)
      assert msg =~ "caído"
      assert w.characters["Sylas"].sorcery_points == 2

      assert {:error, msg_missing} = Actions.create_spell_slot(w, "ghost", 1)
      assert msg_missing =~ "no existe el personaje"
    end
  end

  describe "Actions.convert_to_sorcery_points" do
    test "L2 drena 1 casilla de nivel 1 → +1 punto" do
      w = world([sorcerer(sorcery_points: 0)])

      {:ok, msg, change} = Actions.convert_to_sorcery_points(w, "Sylas", 1)

      assert msg =~ "drena una casilla de nivel 1"
      assert msg =~ "recupera 1 punto de hechicería"
      assert msg =~ "1/2 máx"
      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].sorcery_points == 1
      assert w2.spell_slots["Sylas"][1] == 2
    end

    test "cap al máximo: L2 con 1 punto convierte L1 → 2/2" do
      w = world([sorcerer(sorcery_points: 1)])

      {:ok, msg, change} = Actions.convert_to_sorcery_points(w, "Sylas", 1)

      assert msg =~ "recupera 1 punto de hechicería"
      assert msg =~ "2/2 máx"
      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].sorcery_points == 2
      assert w2.spell_slots["Sylas"][1] == 2
    end

    test "cap con exceso: pool lleno gana 0 y el mensaje muestra el resultado real" do
      w = world([sorcerer(sorcery_points: 2)])

      {:ok, msg, change} = Actions.convert_to_sorcery_points(w, "Sylas", 1)

      assert msg =~ "recupera 0 puntos de hechicería"
      assert msg =~ "2/2 máx"
      assert msg =~ "exceso"
      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].sorcery_points == 2
      assert w2.spell_slots["Sylas"][1] == 2
    end

    test "sin casillas de ese nivel → error sin mutar" do
      w = world([sorcerer([])])

      # L2 sólo tiene casillas de nivel 1.
      assert {:error, msg} = Actions.convert_to_sorcery_points(w, "Sylas", 2)

      assert msg =~ "no le quedan casillas de nivel 2"
      assert w.characters["Sylas"].sorcery_points == 2
      assert w.spell_slots["Sylas"][1] == 3
    end

    test "nivel de casilla 0/6/inválido → error" do
      w = world([sorcerer([])])

      assert {:error, msg0} = Actions.convert_to_sorcery_points(w, "Sylas", 0)
      assert msg0 =~ "nivel de casilla inválido"

      assert {:error, msg6} = Actions.convert_to_sorcery_points(w, "Sylas", 6)
      assert msg6 =~ "nivel de casilla inválido"

      assert {:error, msgx} = Actions.convert_to_sorcery_points(w, "Sylas", :dos)
      assert msgx =~ "nivel de casilla inválido"
    end

    test "no hechicero, L1, caído e inexistente → error" do
      wizard =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 5,
          hp: 20,
          max_hp: 20,
          side: "pc"
        )

      w = world([wizard, sorcerer(level: 1), sorcerer(name: "Vex", hp: 0)])

      assert {:error, msg_class} = Actions.convert_to_sorcery_points(w, "Lyra", 1)
      assert msg_class =~ "no es hechicero"

      assert {:error, msg_l1} = Actions.convert_to_sorcery_points(w, "Sylas", 1)
      assert msg_l1 =~ "nivel 2"

      assert {:error, msg_down} = Actions.convert_to_sorcery_points(w, "Vex", 1)
      assert msg_down =~ "caído"

      assert {:error, msg_missing} = Actions.convert_to_sorcery_points(w, "ghost", 1)
      assert msg_missing =~ "no existe el personaje"
    end
  end

  describe "ida y vuelta" do
    test "crear y convertir deja el pool y las casillas coherentes" do
      w = world([sorcerer([])])

      {:ok, _, create} = Actions.create_spell_slot(w, "Sylas", 1)
      {:ok, w2} = create.(w)
      assert w2.characters["Sylas"].sorcery_points == 0
      assert w2.spell_slots["Sylas"][1] == 4

      {:ok, _, convert} = Actions.convert_to_sorcery_points(w2, "Sylas", 1)
      {:ok, w3} = convert.(w2)
      assert w3.characters["Sylas"].sorcery_points == 1
      assert w3.spell_slots["Sylas"][1] == 3
    end
  end

  describe "rests" do
    test "long rest rellena al máximo (nivel)" do
      w = world([sorcerer(sorcery_points: 0, hp: 8)])

      {:ok, _, rest} = Actions.long_rest(w, "Sylas")
      {:ok, w2} = rest.(w)

      assert w2.characters["Sylas"].sorcery_points == 2
      assert w2.characters["Sylas"].hp == 16
    end

    test "short rest NO rellena puntos de hechicería" do
      w = world([sorcerer(sorcery_points: 1)])

      {:ok, _, rest} = Actions.short_rest(w, "Sylas", seq([4]))
      {:ok, w2} = rest.(w)

      assert w2.characters["Sylas"].sorcery_points == 1
    end

    test "rest de otra clase no toca los puntos" do
      wizard =
        Character.new(name: "Lyra", class: "wizard", level: 5, hp: 10, max_hp: 20, side: "pc")

      w = world([wizard])

      {:ok, _, rest} = Actions.long_rest(w, "Lyra")
      {:ok, w2} = rest.(w)

      assert w2.characters["Lyra"].sorcery_points == 0
    end
  end

  describe "level-up conserva puntos gastados" do
    test "L2 con 1 punto sube a L3 con 2 por la capacidad ganada" do
      w = world([sorcerer(sorcery_points: 1)])

      {:ok, w2} = World.level_up("Sylas", %{}).(w)

      assert w2.characters["Sylas"].level == 3
      # D126: sigue gastado un punto; la capacidad nueva aporta uno más.
      assert w2.characters["Sylas"].sorcery_points == 2
    end
  end

  describe "builder" do
    test "hechicero L1 → 0; L2+ → nivel; otras clases → 0" do
      base = %{name: "X", race: "human", background: "soldier"}

      {:ok, s1} = Dragonex.Heroes.build(Map.merge(base, %{class: "sorcerer"}))
      assert s1.sorcery_points == 0

      {:ok, s3} =
        Dragonex.Heroes.build(Map.merge(base, %{class: "sorcerer", level: 3}))

      assert s3.sorcery_points == 3

      {:ok, f} = Dragonex.Heroes.build(Map.merge(base, %{class: "fighter", level: 5}))
      assert f.sorcery_points == 0
    end
  end

  describe "Codec" do
    test "sorcery_points sobrevive roundtrip" do
      w = world([sorcerer(sorcery_points: 1)])
      assert Codec.decode(Codec.encode(w)).characters["Sylas"].sorcery_points == 1
    end

    test "jsonb viejo/ausente → 0" do
      encoded = sorcerer([]) |> Codec.encode_character() |> Map.delete("sorcery_points")
      refute Map.has_key?(encoded, "sorcery_points")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.sorcery_points == 0
    end
  end

  describe "Tools" do
    setup do
      sylas = sorcerer([])
      g = goblin()

      world =
        World.new(characters: %{"Sylas" => sylas, "goblin" => g})
        |> World.init_spell_slots()

      game =
        start_session(
          world: world,
          policy: :round_robin,
          participants: [p("dm"), p("Sylas")]
        )

      assert {:ok, "dm"} = Session.start(game)
      %{game: game, world: world}
    end

    test "PC otro → RECHAZADO sin mutar", %{game: game} do
      ctx = %{deps: %{state: SharedState.new(game, "Sylas")}}

      assert {:error, msg} = Tools.create_spell_slot(ctx, "goblin", 1)
      assert msg =~ "RECHAZADO"

      assert {:error, msg2} = Tools.convert_to_sorcery_points(ctx, "goblin", 1)
      assert msg2 =~ "RECHAZADO"

      state = Session.read_state(game)
      assert state.characters["Sylas"].sorcery_points == 2
      assert state.spell_slots["Sylas"][1] == 3
    end

    test "DM cualquiera; PC sí mismo", %{game: game} do
      dm = %{deps: %{state: SharedState.new(game, "dm")}}
      assert {:ok, msg} = Tools.create_spell_slot(dm, "Sylas", 1)
      assert msg =~ "teje magia"
      assert Session.read_state(game).characters["Sylas"].sorcery_points == 0
      assert Session.read_state(game).spell_slots["Sylas"][1] == 4

      # Turno del PC: drena SU casilla de nivel 1 y recupera 1 punto.
      assert {:ok, _} = Session.end_turn(game, "dm")
      pc = %{deps: %{state: SharedState.new(game, "Sylas")}}
      assert {:ok, msg2} = Tools.convert_to_sorcery_points(pc, "Sylas", 1)
      assert msg2 =~ "drena una casilla de nivel 1"
      assert Session.read_state(game).characters["Sylas"].sorcery_points == 1
      assert Session.read_state(game).spell_slots["Sylas"][1] == 3
    end

    test "errores del motor pasan por la tool sin mutar", %{game: game} do
      dm = %{deps: %{state: SharedState.new(game, "dm")}}
      assert {:error, msg} = Tools.create_spell_slot(dm, "ghost", 1)
      assert msg =~ "no existe el personaje"
    end
  end

  describe "agentes" do
    test "PCAgent expone las tools y las líneas de combate del hechicero L2+" do
      names = PCAgent.tools() |> Enum.map(&to_string(&1.name))
      assert "create_spell_slot" in names
      assert "convert_to_sorcery_points" in names

      sylas = sorcerer([])
      g = goblin()

      combat =
        World.new(phase: :combat, characters: %{"Sylas" => sylas, "goblin" => g})
        |> World.init_spell_slots()

      instr = PCAgent.instruction("Sylas", sylas, combat)
      assert instr =~ "create_spell_slot"
      assert instr =~ "convert_to_sorcery_points"

      # Sin puntos no hay línea de crear; sin casillas (mundo sin traccionar
      # spell_slots) no hay línea de convertir.
      broke = sorcerer(sorcery_points: 0)

      bare =
        World.new(phase: :combat, characters: %{"Sylas" => broke, "goblin" => g})

      refute PCAgent.instruction("Sylas", broke, bare) =~ "create_spell_slot"
      refute PCAgent.instruction("Sylas", broke, bare) =~ "convert_to_sorcery_points"
    end

    test "DM prompt menciona las dos tools" do
      assert Dragonex.DM.system_prompt() =~ "create_spell_slot"
      assert Dragonex.DM.system_prompt() =~ "convert_to_sorcery_points"
    end

    test "Text.scrub elimina las calls narradas en prosa" do
      text =
        "Sylas usa create_spell_slot(\"Sylas\", 2) y luego convert_to_sorcery_points(\"Sylas\", 1)."

      scrubbed = Text.scrub(text)
      refute scrubbed =~ "create_spell_slot"
      refute scrubbed =~ "convert_to_sorcery_points"
    end
  end
end
