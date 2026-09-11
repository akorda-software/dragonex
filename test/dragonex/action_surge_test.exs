defmodule Dragonex.ActionSurgeTest do
  @moduledoc """
  Action Surge 5e (D47): fighter L2+ extra Attack action 1/rest.
  Extra Attack (D35) intact. No Fighting Style. No Indomitable. No L17.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Tools, Weapon, World}
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

  defp fighter(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          level: 2,
          hp: 18,
          max_hp: 18,
          ac: 16,
          str: 16,
          dex: 12,
          con: 14,
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
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  describe "Actions.action_surge" do
    test "L2 fighter extra Attack action; used=true" do
      w = world([fighter([]), goblin()])

      # L2: prof 2 + str 3 = +5. d20=10 → 15 vs CA 12 hit; d8=4 +3 = 7.
      {:ok, msg, change} =
        Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "Oleada de acción"
      assert msg =~ "acierta"
      refute msg =~ "2 golpes"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 7
      assert w2.characters["Thane"].action_surge_used == true
    end

    test "Extra Attack L5 → 2 swings en el surge" do
      w = world([fighter(level: 5), goblin()])

      # L5: prof 3 + str 3 = +6. d20=10 → 16 vs CA 12 hit; d8=4 +3 = 7. Dos veces.
      {:ok, msg, change} =
        Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4, 10, 4]))

      assert msg =~ "Oleada de acción"
      assert msg =~ "2 golpes"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30 - 14
      assert w2.characters["Thane"].action_surge_used == true
    end

    test "miss también gasta el uso" do
      w = world([fighter([]), goblin()])

      {:ok, msg, change} =
        Actions.action_surge(w, "Thane", "goblin", "longsword", seq([1]))

      assert msg =~ "Oleada de acción"
      assert msg =~ "fallo"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30
      assert w2.characters["Thane"].action_surge_used == true
    end

    test "L1 error; no marca" do
      w = world([fighter(level: 1), goblin()])

      assert {:error, msg} =
               Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "nivel 2"
      refute w.characters["Thane"].action_surge_used
    end

    test "no fighter error; no marca" do
      wiz =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 5,
          hp: 20,
          max_hp: 20,
          side: "pc",
          weapons: [longsword()]
        )

      w = world([wiz, goblin()])

      assert {:error, msg} =
               Actions.action_surge(w, "Lyra", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "no es guerrero"
    end

    test "segundo uso error" do
      w = world([fighter([]), goblin()])
      {:ok, _, change} = Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))
      {:ok, w} = change.(w)

      assert {:error, msg} =
               Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "ya ha usado"
    end

    test "sin arma no marca" do
      w = world([fighter([]), goblin()])

      assert {:error, msg} =
               Actions.action_surge(w, "Thane", "goblin", "greatsword", seq([10, 4]))

      assert msg =~ "no tiene el arma"
      refute w.characters["Thane"].action_surge_used
    end

    test "0 hp no marca" do
      w = world([fighter(hp: 0), goblin()])

      assert {:error, msg} =
               Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "caído"
      refute w.characters["Thane"].action_surge_used
    end

    test "missing character error" do
      assert {:error, msg} =
               Actions.action_surge(World.new(), "ghost", "goblin", "longsword", seq([10, 4]))

      assert msg =~ "no existe"
    end
  end

  describe "rest recarga" do
    test "short_rest recarga" do
      w = world([fighter([]), goblin()])
      {:ok, _, change} = Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))
      {:ok, w} = change.(w)
      assert w.characters["Thane"].action_surge_used == true

      {:ok, _, rest} = Actions.short_rest(w, "Thane", seq([4]))
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].action_surge_used == false

      {:ok, _, change2} = Actions.action_surge(w, "Thane", "goblin", "longsword", seq([10, 4]))
      {:ok, w} = change2.(w)
      assert w.characters["Thane"].action_surge_used == true
    end

    test "long_rest recarga aunque no gaste hit die" do
      w = world([fighter(hp: 18, max_hp: 18, action_surge_used: true), goblin()])

      {:ok, _, rest} = Actions.long_rest(w, "Thane")
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].action_surge_used == false
      assert w.characters["Thane"].hp == 18
    end
  end

  describe "Codec roundtrip" do
    test "action_surge_used survives" do
      w = world([fighter(action_surge_used: true)])
      assert Codec.decode(Codec.encode(w)).characters["Thane"].action_surge_used == true
    end

    test "absent in old jsonb is false" do
      encoded = fighter([]) |> Codec.encode_character() |> Map.delete("action_surge_used")
      refute Map.has_key?(encoded, "action_surge_used")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.action_surge_used == false
    end
  end

  describe "Tools.action_surge" do
    test "PC otro error" do
      thane = fighter([])
      vex = fighter(name: "Vex")
      g = goblin()

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane, "Vex" => vex, "goblin" => g}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Thane"), roller: seq([10, 4])}}
      assert {:error, msg} = Tools.action_surge(ctx, "Vex", "goblin", "longsword", "normal")
      assert msg =~ "RECHAZADO"
      refute Session.read_state(game).characters["Vex"].action_surge_used
    end

    test "DM cualquiera; PC sí mismo" do
      thane = fighter([])
      g = goblin()

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane, "goblin" => g}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: seq([10, 4])}}
      assert {:ok, msg} = Tools.action_surge(dm, "Thane", "goblin", "longsword", "normal")
      assert msg =~ "Oleada de acción"
      assert Session.read_state(game).characters["Thane"].action_surge_used == true
    end
  end
end
