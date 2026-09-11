defmodule Dragonex.LayOnHandsTest do
  @moduledoc """
  Lay on Hands 5e (D49): paladin pool 5*level, heal self or ally.
  No disease/poison. No Divine Sense.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp paladin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Rhogar",
          class: "paladin",
          race: "human",
          level: 1,
          hp: 10,
          max_hp: 18,
          ac: 18,
          str: 16,
          dex: 10,
          con: 14,
          cha: 15,
          side: "pc",
          lay_on_hands_pool: 5
        ],
        opts
      )
    )
  end

  defp ally(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          race: "human",
          level: 1,
          hp: 5,
          max_hp: 22,
          ac: 16,
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

  describe "Actions.lay_on_hands/4" do
    test "paladin cura a un aliado y gasta applied del pool" do
      w = world([paladin([]), ally([])])

      {:ok, msg, change} = Actions.lay_on_hands(w, "Rhogar", "Thane", 3)

      assert msg =~ "Rhogar usa Manos impositoras en Thane"
      assert msg =~ "cura 3 pg"
      assert msg =~ "pool 2"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 8
      assert w2.characters["Rhogar"].lay_on_hands_pool == 2
      assert w2.characters["Rhogar"].hp == 10
    end

    test "puede curarse a sí mismo" do
      w = world([paladin([])])

      {:ok, msg, change} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 4)

      assert msg =~ "en Rhogar"
      assert msg =~ "cura 4 pg"
      {:ok, w2} = change.(w)
      assert w2.characters["Rhogar"].hp == 14
      assert w2.characters["Rhogar"].lay_on_hands_pool == 1
    end

    test "caps at max_hp y gasta applied, no el amount pedido" do
      w = world([paladin(hp: 16, max_hp: 18, lay_on_hands_pool: 5)])

      {:ok, msg, change} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 5)

      assert msg =~ "cura 2 pg"
      assert msg =~ "pool 3"
      {:ok, w2} = change.(w)
      assert w2.characters["Rhogar"].hp == 18
      assert w2.characters["Rhogar"].lay_on_hands_pool == 3
    end

    test "who no existe" do
      assert {:error, msg} = Actions.lay_on_hands(World.new(), "ghost", "ghost", 1)
      assert msg =~ "no existe"
    end

    test "target no existe" do
      w = world([paladin([])])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "ghost", 1)
      assert msg =~ "no existe"
      assert w.characters["Rhogar"].lay_on_hands_pool == 5
    end

    test "no paladin error" do
      w = world([ally([])])
      assert {:error, msg} = Actions.lay_on_hands(w, "Thane", "Thane", 1)
      assert msg =~ "no es paladín"
    end

    test "amount no entero >= 1" do
      w = world([paladin([])])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 0)
      assert msg =~ "entero"
      assert {:error, _} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", -2)
      assert {:error, _} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 1.5)
      assert {:error, _} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", "3")
      assert w.characters["Rhogar"].lay_on_hands_pool == 5
    end

    test "pool 0 error" do
      w = world([paladin(lay_on_hands_pool: 0)])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 1)
      assert msg =~ "no tiene puntos"
    end

    test "amount > pool error no gasta" do
      w = world([paladin(lay_on_hands_pool: 2)])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 5)
      assert msg =~ "suficientes"
      assert w.characters["Rhogar"].lay_on_hands_pool == 2
    end

    test "objetivo a tope applied 0" do
      w = world([paladin(hp: 18, max_hp: 18)])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 2)
      assert msg =~ "a tope"
      assert w.characters["Rhogar"].lay_on_hands_pool == 5
    end

    test "undead error no gasta" do
      w = world([paladin([]), ally(name: "Wight", race: "Undead", hp: 3, max_hp: 20)])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "Wight", 3)
      assert msg =~ ~r/no-muerto|constructo/
      assert w.characters["Rhogar"].lay_on_hands_pool == 5
      assert w.characters["Wight"].hp == 3
    end

    test "construct error no gasta" do
      w = world([paladin([]), ally(name: "Golem", race: "construct", hp: 3, max_hp: 20)])
      assert {:error, msg} = Actions.lay_on_hands(w, "Rhogar", "Golem", 3)
      assert msg =~ ~r/no-muerto|constructo/
      assert w.characters["Rhogar"].lay_on_hands_pool == 5
    end

    test "no toca temp_hp; death saves si hp>0" do
      w =
        world([
          paladin(
            hp: 0,
            max_hp: 18,
            temp_hp: 4,
            death_saves: %{successes: 1, fails: 2},
            lay_on_hands_pool: 5
          )
        ])

      {:ok, _, change} = Actions.lay_on_hands(w, "Rhogar", "Rhogar", 3)
      {:ok, w2} = change.(w)
      c = w2.characters["Rhogar"]
      assert c.hp == 3
      assert c.temp_hp == 4
      assert c.death_saves == %{successes: 0, fails: 0}
      assert c.lay_on_hands_pool == 2
    end
  end

  describe "World.lay_on_hands/3" do
    test "resta pool y cura" do
      w = world([paladin([]), ally([])])
      {:ok, w2} = World.lay_on_hands("Rhogar", "Thane", 4).(w)
      assert w2.characters["Thane"].hp == 9
      assert w2.characters["Rhogar"].lay_on_hands_pool == 1
    end

    test "no paladin error" do
      w = world([ally([])])
      assert {:error, msg} = World.lay_on_hands("Thane", "Thane", 1).(w)
      assert msg =~ "no es paladín"
    end
  end

  describe "rest recarga" do
    test "short_rest NO recarga el pool" do
      w = world([paladin(hp: 10, max_hp: 18, lay_on_hands_pool: 1, con: 14)])
      {:ok, _, rest} = Actions.short_rest(w, "Rhogar", Dragonex.Dice.always(4))
      {:ok, w} = rest.(w)
      assert w.characters["Rhogar"].lay_on_hands_pool == 1
    end

    test "long_rest recarga a 5*level" do
      w = world([paladin(hp: 18, max_hp: 18, lay_on_hands_pool: 1, level: 3)])
      {:ok, _, rest} = Actions.long_rest(w, "Rhogar")
      {:ok, w} = rest.(w)
      assert w.characters["Rhogar"].lay_on_hands_pool == 15
      assert w.characters["Rhogar"].hp == 18
    end

    test "long_rest de no paladin no toca un pool 0" do
      w = world([ally(hp: 22, max_hp: 22)])
      {:ok, _, rest} = Actions.long_rest(w, "Thane")
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].lay_on_hands_pool == 0
    end
  end

  describe "level-up / merge conservan remaining" do
    test "World.level_up no resetea el pool" do
      w = world([paladin(level: 1, lay_on_hands_pool: 3)])
      {:ok, w2} = World.level_up("Rhogar", %{}).(w)
      assert w2.characters["Rhogar"].level == 2
      assert w2.characters["Rhogar"].lay_on_hands_pool == 3
    end

    test "Games.merge_character_level_up no pisa el pool vivo" do
      live = paladin(level: 1, lay_on_hands_pool: 2, hp: 4)
      sheet = %{live | level: 2, max_hp: 25, lay_on_hands_pool: 10}
      w = world([live])
      w2 = Games.merge_character_level_up(w, "Rhogar", sheet)
      assert w2.characters["Rhogar"].level == 2
      assert w2.characters["Rhogar"].lay_on_hands_pool == 2
      assert w2.characters["Rhogar"].hp == 4
    end
  end

  describe "Heroes.build" do
    test "paladin L1 pool 5" do
      {:ok, c} =
        Heroes.build(%{name: "Rhogar", race: "human", class: "paladin", background: "soldier"})

      assert c.lay_on_hands_pool == 5
    end

    test "paladin con choices.level usa 5*level" do
      {:ok, c} =
        Heroes.build(%{
          name: "Rhogar",
          race: "human",
          class: "paladin",
          background: "soldier",
          level: 4
        })

      assert c.lay_on_hands_pool == 20
    end

    test "no paladin pool 0" do
      {:ok, c} =
        Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

      assert c.lay_on_hands_pool == 0
    end
  end

  describe "Codec" do
    test "lay_on_hands_pool survives" do
      c = paladin(lay_on_hands_pool: 7)
      w = world([c])
      assert Codec.decode(Codec.encode(w)).characters["Rhogar"].lay_on_hands_pool == 7
    end

    test "absent in old jsonb is 0" do
      encoded = paladin([]) |> Codec.encode_character() |> Map.delete("lay_on_hands_pool")
      refute Map.has_key?(encoded, "lay_on_hands_pool")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.lay_on_hands_pool == 0
    end
  end

  describe "Tools.lay_on_hands" do
    test "PC otro who error" do
      rhogar = paladin([])
      vex = paladin(name: "Vex", hp: 8)

      game =
        start_session(
          world: World.new(characters: %{"Rhogar" => rhogar, "Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Rhogar"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Rhogar"), roller: fixed_roller(7)}}
      assert {:error, msg} = Tools.lay_on_hands(ctx, "Vex", "Rhogar", 2)
      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["Vex"].lay_on_hands_pool == 5
      assert Session.read_state(game).characters["Rhogar"].hp == 10
    end

    test "PC sí mismo puede curar aliado" do
      rhogar = paladin([])
      thane = ally([])

      game =
        start_session(
          world: World.new(characters: %{"Rhogar" => rhogar, "Thane" => thane}),
          policy: :round_robin,
          participants: [p("Rhogar"), p("Thane")]
        )

      assert {:ok, "Rhogar"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Rhogar"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.lay_on_hands(pc, "Rhogar", "Thane", 2)
      assert msg =~ "cura 2 pg"
      assert Session.read_state(game).characters["Thane"].hp == 7
      assert Session.read_state(game).characters["Rhogar"].lay_on_hands_pool == 3
    end

    test "DM cualquiera" do
      rhogar = paladin([])

      game =
        start_session(
          world: World.new(characters: %{"Rhogar" => rhogar}),
          policy: :round_robin,
          participants: [p("dm"), p("Rhogar")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.lay_on_hands(dm, "Rhogar", "Rhogar", 3)
      assert msg =~ "cura 3 pg"
      assert Session.read_state(game).characters["Rhogar"].hp == 13
      assert Session.read_state(game).characters["Rhogar"].lay_on_hands_pool == 2
    end
  end
end
