defmodule Dragonex.SecondWindTest do
  @moduledoc """
  Second Wind 5e (D45): fighter heals 1d10+level once per rest.
  No Action Surge. No feats.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp fighter(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          level: 1,
          hp: 5,
          max_hp: 22,
          ac: 16,
          str: 16,
          dex: 12,
          con: 14,
          side: "pc"
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

  describe "Actions.second_wind/4" do
    test "fighter cura 1d10+level" do
      w = world([fighter([])])

      {:ok, msg, change} = Actions.second_wind(w, "Thane", fixed(7))

      assert msg =~ "1d10+1 = 8"
      assert msg =~ "se cura 8 pg"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 13
      assert w2.characters["Thane"].second_wind_used == true
    end

    test "level 5 suma +5" do
      w = world([fighter(level: 5, hp: 10, max_hp: 40)])

      {:ok, msg, change} = Actions.second_wind(w, "Thane", fixed(4))

      assert msg =~ "1d10+5 = 9"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 19
    end

    test "caps at max_hp" do
      w = world([fighter(hp: 20, max_hp: 22)])

      {:ok, msg, change} = Actions.second_wind(w, "Thane", fixed(10))

      assert msg =~ "se cura 2 pg"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 22
      assert w2.characters["Thane"].second_wind_used == true
    end

    test "segundo uso error" do
      w = world([fighter([])])
      {:ok, _, change} = Actions.second_wind(w, "Thane", fixed(7))
      {:ok, w} = change.(w)

      assert {:error, msg} = Actions.second_wind(w, "Thane", fixed(7))
      assert msg =~ "ya ha usado"
    end

    test "no fighter error" do
      w = world([Character.new(name: "Lyra", class: "wizard", hp: 3, max_hp: 7, side: "pc")])

      assert {:error, msg} = Actions.second_wind(w, "Lyra", fixed(7))
      assert msg =~ "no es guerrero"
    end

    test "missing character error" do
      assert {:error, msg} = Actions.second_wind(World.new(), "ghost", fixed(7))
      assert msg =~ "no existe"
    end

    test "no toca temp_hp al curar a un guerrero consciente" do
      w =
        world([
          fighter(
            hp: 1,
            max_hp: 22,
            temp_hp: 4,
            death_saves: %{successes: 0, fails: 0}
          )
        ])

      {:ok, _, change} = Actions.second_wind(w, "Thane", fixed(6))
      {:ok, w2} = change.(w)
      c = w2.characters["Thane"]
      assert c.hp == 8
      assert c.temp_hp == 4
      assert c.death_saves == %{successes: 0, fails: 0}
    end
  end

  describe "rest recarga" do
    test "short_rest recarga" do
      w = world([fighter([])])
      {:ok, _, change} = Actions.second_wind(w, "Thane", fixed(7))
      {:ok, w} = change.(w)
      assert w.characters["Thane"].second_wind_used == true

      {:ok, _, rest} = Actions.short_rest(w, "Thane", fixed(4))
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].second_wind_used == false

      {:ok, _, change2} = Actions.second_wind(w, "Thane", fixed(3))
      {:ok, w} = change2.(w)
      assert w.characters["Thane"].second_wind_used == true
    end

    test "long_rest recarga aunque no gaste hit die" do
      w = world([fighter(hp: 22, max_hp: 22, second_wind_used: true)])

      {:ok, _, rest} = Actions.long_rest(w, "Thane")
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].second_wind_used == false
      assert w.characters["Thane"].hp == 22
    end
  end

  describe "Tools.second_wind" do
    test "PC otro error" do
      thane = fighter([])
      vex = fighter(name: "Vex")

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane, "Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Thane"), roller: fixed_roller(7)}}
      assert {:error, msg} = Tools.second_wind(ctx, "Vex")
      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["Vex"].hp == 5
      refute Session.read_state(game).characters["Vex"].second_wind_used
    end

    test "DM cualquiera; PC sí mismo" do
      thane = fighter([])

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.second_wind(dm, "Thane")
      assert msg =~ "se cura 8 pg"
      assert Session.read_state(game).characters["Thane"].second_wind_used == true
    end
  end
end
