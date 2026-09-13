defmodule Dragonex.FlurryOfBlowsTest do
  @moduledoc """
  Ki + Flurry of Blows 5e (D54): monk L2+ gasta 1 ki → 2 golpes sin armas
  (dado de artes marciales). Sin Patient Defense, Step of the Wind,
  Stunning Strike, Deflect Missiles, Martial Arts "golpe extra tras Attack",
  Unarmored Movement, feats ni multiclase.
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

  defp monk(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Shen",
          class: "monk",
          level: 2,
          ki: 2,
          hp: 16,
          max_hp: 16,
          ac: 15,
          str: 10,
          dex: 16,
          con: 10,
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

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  describe "Progression" do
    test "martial_arts_die por nivel" do
      assert Progression.martial_arts_die(1) == "1d4"
      assert Progression.martial_arts_die(4) == "1d4"
      assert Progression.martial_arts_die(5) == "1d6"
      assert Progression.martial_arts_die(10) == "1d6"
      assert Progression.martial_arts_die(11) == "1d8"
      assert Progression.martial_arts_die(16) == "1d8"
      assert Progression.martial_arts_die(17) == "1d10"
      assert Progression.martial_arts_die(20) == "1d10"
    end

    test "ki_points: monk L2+ → nivel; L1 y otras clases → 0" do
      assert Progression.ki_points("monk", 2) == 2
      assert Progression.ki_points("monk", 5) == 5
      assert Progression.ki_points("monk", 1) == 0
      assert Progression.ki_points("fighter", 5) == 0
      assert Progression.ki_points("wizard", 20) == 0
    end
  end

  describe "Actions.flurry_of_blows" do
    test "L2 ki=2: gasta 1 ki y resuelve 2 golpes sin armas" do
      w = world([monk([]), goblin()])

      # L2: prof 2 + dex 3 = +5 (finesse). d20=10 → 15 vs CA 12 hit;
      # artes marciales 1d4=3 + dex 3 = 6. Dos veces → 12.
      {:ok, msg, change} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([10, 3, 10, 3]))

      assert msg =~ "Ráfaga de golpes"
      assert msg =~ "ki restantes 1"
      assert msg =~ "2 golpes"
      assert msg =~ "bludgeoning"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 12
      assert w2.characters["Shen"].ki == 1
    end

    test "miss también gasta el ki" do
      w = world([monk([]), goblin()])

      # d20=2 → 7 vs CA 12: fallo x2. Sin tirada de daño en miss.
      {:ok, msg, change} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([2, 2]))

      assert msg =~ "Ráfaga de golpes"
      assert msg =~ "ki restantes 1"
      assert msg =~ "fallo"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30
      assert w2.characters["Shen"].ki == 1
    end

    test "dado L5 = 1d6" do
      w = world([monk(level: 5, ki: 5), goblin()])

      # L5: prof 3 + dex 3 = +6. d20=10 → 16 vs CA 12 hit; 1d6=4 + 3 = 7. x2.
      {:ok, msg, change} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([10, 4, 10, 4]))

      assert msg =~ "ki restantes 4"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 14
      assert w2.characters["Shen"].ki == 4
    end

    test "objetivo cae a mitad: omite el segundo swing, ki gastado igual" do
      w = world([monk([]), goblin(hp: 6, max_hp: 6)])

      {:ok, msg, change} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([10, 3, 10, 3]))

      refute msg =~ "2 golpes"
      assert msg =~ "acierta"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 0
      assert w2.characters["Shen"].ki == 1
    end

    test "monje L1 error; no gasta" do
      w = world([monk(level: 1, ki: 0), goblin()])

      assert {:error, msg} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([10, 3]))

      assert msg =~ "nivel 2"
      assert w.characters["Shen"].ki == 0
    end

    test "no monje error; no gasta" do
      fighter =
        Character.new(
          name: "Thane",
          class: "fighter",
          level: 5,
          ki: 5,
          hp: 20,
          max_hp: 20,
          side: "pc"
        )

      w = world([fighter, goblin()])

      assert {:error, msg} = Actions.flurry_of_blows(w, "Thane", "goblin", seq([10, 3]))

      assert msg =~ "no es monje"
      assert w.characters["Thane"].ki == 5
    end

    test "ki 0 error" do
      w = world([monk(ki: 0), goblin()])

      assert {:error, msg} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([10, 3]))

      assert msg =~ "no tiene ki"
      assert w.characters["Shen"].ki == 0
    end

    test "monje caído error; no gasta" do
      w = world([monk(hp: 0), goblin()])

      assert {:error, msg} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([10, 3]))

      assert msg =~ "caído"
      assert w.characters["Shen"].ki == 2
    end

    test "who/target inexistentes error" do
      w = world([monk([]), goblin()])

      assert {:error, msg} = Actions.flurry_of_blows(w, "ghost", "goblin", seq([10, 3]))
      assert msg =~ "no existe el personaje"

      assert {:error, msg} = Actions.flurry_of_blows(w, "Shen", "ghost", seq([10, 3]))
      assert msg =~ "no existe el objetivo"
      assert w.characters["Shen"].ki == 2
    end
  end

  describe "rests recargan ki" do
    test "short_rest recarga al nivel" do
      w = world([monk([]), goblin()])
      {:ok, _, change} = Actions.flurry_of_blows(w, "Shen", "goblin", seq([2, 2]))
      {:ok, w} = change.(w)
      assert w.characters["Shen"].ki == 1

      {:ok, _, rest} = Actions.short_rest(w, "Shen", seq([4]))
      {:ok, w} = rest.(w)
      assert w.characters["Shen"].ki == 2
    end

    test "long_rest recarga al nivel" do
      w = world([monk(ki: 0, hp: 8), goblin()])

      {:ok, _, rest} = Actions.long_rest(w, "Shen")
      {:ok, w} = rest.(w)

      assert w.characters["Shen"].ki == 2
      assert w.characters["Shen"].hp == 16
    end

    test "rest de otra clase no toca ki" do
      wizard =
        Character.new(name: "Lyra", class: "wizard", level: 5, hp: 10, max_hp: 20, side: "pc")

      w = world([wizard])

      {:ok, _, rest} = Actions.short_rest(w, "Lyra", seq([4]))
      {:ok, w} = rest.(w)
      assert w.characters["Lyra"].ki == 0
    end
  end

  describe "level-up no resetea ki restante" do
    test "L2 ki=1 sube a L3 y conserva ki=1" do
      w = world([monk(ki: 1)])

      {:ok, w2} = World.level_up("Shen", %{}).(w)

      assert w2.characters["Shen"].level == 3
      assert w2.characters["Shen"].ki == 1
    end
  end

  describe "builder" do
    test "monje L1 → ki 0; L2+ → nivel; otras clases → 0" do
      base = %{name: "X", race: "human", background: "soldier"}

      {:ok, m1} = Dragonex.Heroes.build(Map.merge(base, %{class: "monk"}))
      assert m1.ki == 0

      {:ok, m3} =
        Dragonex.Heroes.build(Map.merge(base, %{class: "monk", level: 3}))

      assert m3.ki == 3

      {:ok, f} = Dragonex.Heroes.build(Map.merge(base, %{class: "fighter", level: 5}))
      assert f.ki == 0
    end
  end

  describe "Codec" do
    test "ki survives roundtrip" do
      w = world([monk(ki: 1)])
      assert Codec.decode(Codec.encode(w)).characters["Shen"].ki == 1
    end

    test "jsonb viejo/ausente → 0" do
      encoded = monk([]) |> Codec.encode_character() |> Map.delete("ki")
      refute Map.has_key?(encoded, "ki")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.ki == 0
    end
  end

  describe "Tools.flurry_of_blows" do
    setup do
      shen = monk([])
      g = goblin()

      game =
        start_session(
          world: World.new(characters: %{"Shen" => shen, "goblin" => g}),
          policy: :round_robin,
          participants: [p("dm"), p("Shen")]
        )

      assert {:ok, "dm"} = Session.start(game)
      %{game: game}
    end

    test "PC otro error", %{game: game} do
      ctx = %{deps: %{state: SharedState.new(game, "Shen"), roller: seq([10, 3, 10, 3])}}
      assert {:error, msg} = Tools.flurry_of_blows(ctx, "goblin", "goblin", "normal")
      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["goblin"].ki == 0
    end

    test "DM cualquiera; PC sí mismo", %{game: game} do
      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: seq([10, 3, 10, 3])}}
      assert {:ok, msg} = Tools.flurry_of_blows(dm, "Shen", "goblin", "normal")
      assert msg =~ "Ráfaga de golpes"
      assert Session.read_state(game).characters["Shen"].ki == 1
      assert Session.read_state(game).characters["goblin"].hp == 30 - 12

      # Turno del PC: puede gastar SU ki (le queda 1; el flurry falla x2).
      assert {:ok, _} = Session.end_turn(game, "dm")
      pc = %{deps: %{state: SharedState.new(game, "Shen"), roller: seq([2, 2])}}
      assert {:ok, _} = Tools.flurry_of_blows(pc, "Shen", "goblin", "normal")
      assert Session.read_state(game).characters["Shen"].ki == 0
    end
  end

  describe "agentes" do
    test "PCAgent expone la tool y la línea de combate si ki > 0" do
      names = PCAgent.tools() |> Enum.map(&to_string(&1.name))
      assert "flurry_of_blows" in names

      shen = monk([])
      g = goblin()

      combat = World.new(phase: :combat, characters: %{"Shen" => shen, "goblin" => g})
      instr = PCAgent.instruction("Shen", shen, combat)
      assert instr =~ "flurry_of_blows"

      vacio = monk(ki: 0)
      combat0 = World.new(phase: :combat, characters: %{"Shen" => vacio, "goblin" => g})
      refute PCAgent.instruction("Shen", vacio, combat0) =~ "flurry_of_blows"
    end

    test "DM prompt menciona la tool" do
      assert Dragonex.DM.system_prompt() =~ "flurry_of_blows"
    end

    test "Text.scrub elimina flurry_of_blows narrado en prosa" do
      text = "Shen usa flurry_of_blows(\"Shen\", \"goblin\", \"normal\") y golpea dos veces."
      refute Text.scrub(text) =~ "flurry_of_blows"
    end
  end
end
