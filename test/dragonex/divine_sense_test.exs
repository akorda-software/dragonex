defmodule Dragonex.DivineSenseTest do
  @moduledoc """
  Divine Sense 5e (D52): paladin spends 1 use; engine reports celestial/
  fiend/undead by race. Combat allowed. Long rest refills.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp paladin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "paladin",
          race: "human",
          level: 1,
          hp: 12,
          max_hp: 12,
          ac: 18,
          str: 16,
          dex: 10,
          con: 14,
          cha: 16,
          side: "pc",
          divine_sense_uses: 4
        ],
        opts
      )
    )
  end

  defp fighter(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Rhogar",
          class: "fighter",
          race: "human",
          level: 1,
          hp: 12,
          max_hp: 12,
          ac: 16,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp monster(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Goblin",
          class: "monster",
          race: "humanoid",
          level: 1,
          hp: 7,
          max_hp: 7,
          ac: 15,
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

  describe "Actions.divine_sense/2" do
    test "detecta undead, fiend y celestial por race; no detecta humanoid" do
      w =
        world([
          paladin([]),
          monster(name: "Esqueleto", race: "Undead"),
          monster(name: "Imp", race: "fiend"),
          monster(name: "Deva", race: "celestial"),
          monster(name: "Goblin", race: "humanoid")
        ])

      {:ok, msg, change} = Actions.divine_sense(w, "Thane")

      assert msg ==
               "Thane usa Sentido divino y percibe: Deva (celestial), Esqueleto (no-muerto), Imp (infernal) (usos restantes 3)."

      refute msg =~ "Goblin"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].divine_sense_uses == 3
    end

    test "incluye hp <= 0 y no incluye a who" do
      w =
        world([
          paladin(race: "undead"),
          monster(name: "Esqueleto", race: "undead", hp: 0)
        ])

      {:ok, msg, change} = Actions.divine_sense(w, "Thane")

      assert msg =~ "Esqueleto (no-muerto)"
      refute msg =~ "Thane ("
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].divine_sense_uses == 3
    end

    test "gasta 1 uso aunque el scan esté vacío" do
      w = world([paladin([]), monster([])])

      {:ok, msg, change} = Actions.divine_sense(w, "Thane")

      assert msg ==
               "Thane usa Sentido divino y no percibe celestiales, infernales ni no-muertos (usos restantes 3)."

      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].divine_sense_uses == 3
    end

    test "permitido en combate" do
      w = %{world([paladin([]), monster(name: "Esqueleto", race: "undead")]) | phase: :combat}

      {:ok, msg, change} = Actions.divine_sense(w, "Thane")
      assert msg =~ "Esqueleto (no-muerto)"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].divine_sense_uses == 3
    end

    test "0 usos error no escanea" do
      w = world([paladin(divine_sense_uses: 0), monster(name: "Esqueleto", race: "undead")])
      assert {:error, msg} = Actions.divine_sense(w, "Thane")
      assert msg =~ "no tiene usos"
      assert w.characters["Thane"].divine_sense_uses == 0
    end

    test "no paladín error" do
      w = world([fighter([])])
      assert {:error, msg} = Actions.divine_sense(w, "Rhogar")
      assert msg =~ "no es paladín"
    end

    test "who no existe" do
      assert {:error, msg} = Actions.divine_sense(World.new(), "ghost")
      assert msg =~ "no existe"
    end
  end

  describe "World.spend_divine_sense/1" do
    test "gasta 1 uso" do
      w = world([paladin([])])
      {:ok, w2} = World.spend_divine_sense("Thane").(w)
      assert w2.characters["Thane"].divine_sense_uses == 3
    end

    test "no paladín error" do
      w = world([fighter([])])
      assert {:error, msg} = World.spend_divine_sense("Rhogar").(w)
      assert msg =~ "no es paladín"
    end
  end

  describe "rest recarga" do
    test "short_rest NO recarga usos" do
      w = world([paladin(hp: 10, max_hp: 12, divine_sense_uses: 1, con: 14)])
      {:ok, _, rest} = Actions.short_rest(w, "Thane", Dragonex.Dice.always(4))
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].divine_sense_uses == 1
    end

    test "long_rest recarga a max(1, 1+cha_mod); Cha 16 → 4" do
      w = world([paladin(hp: 12, max_hp: 12, divine_sense_uses: 1, cha: 16)])
      {:ok, _, rest} = Actions.long_rest(w, "Thane")
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].divine_sense_uses == 4
    end

    test "long_rest de no paladin no toca usos 0" do
      w = world([fighter(hp: 12, max_hp: 12)])
      {:ok, _, rest} = Actions.long_rest(w, "Rhogar")
      {:ok, w} = rest.(w)
      assert w.characters["Rhogar"].divine_sense_uses == 0
    end
  end

  describe "level-up / merge conservan remaining" do
    test "World.level_up no resetea usos" do
      w = world([paladin(level: 1, divine_sense_uses: 2)])
      {:ok, w2} = World.level_up("Thane", %{}).(w)
      assert w2.characters["Thane"].level == 2
      assert w2.characters["Thane"].divine_sense_uses == 2
    end

    test "Games.merge_character_level_up no pisa usos vivos" do
      live = paladin(level: 1, divine_sense_uses: 1, hp: 4)
      sheet = %{live | level: 2, max_hp: 22, divine_sense_uses: 4}
      w = world([live])
      w2 = Games.merge_character_level_up(w, "Thane", sheet)
      assert w2.characters["Thane"].level == 2
      assert w2.characters["Thane"].divine_sense_uses == 1
      assert w2.characters["Thane"].hp == 4
    end
  end

  describe "Heroes.build" do
    test "paladin Cha 16 → 4 usos" do
      {:ok, c} =
        Heroes.build(%{
          name: "Thane",
          race: "human",
          class: "paladin",
          background: "soldier",
          scores: %{str: 15, dex: 8, con: 14, int: 8, wis: 10, cha: 15}
        })

      assert c.cha == 16
      assert c.divine_sense_uses == 4
    end

    test "no paladin usos 0" do
      {:ok, c} =
        Heroes.build(%{name: "Rhogar", race: "human", class: "fighter", background: "soldier"})

      assert c.divine_sense_uses == 0
    end
  end

  describe "Codec" do
    test "divine_sense_uses survives" do
      c = paladin(divine_sense_uses: 3)
      w = world([c])
      assert Codec.decode(Codec.encode(w)).characters["Thane"].divine_sense_uses == 3
    end

    test "absent in old jsonb is 0" do
      encoded = paladin([]) |> Codec.encode_character() |> Map.delete("divine_sense_uses")
      refute Map.has_key?(encoded, "divine_sense_uses")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.divine_sense_uses == 0
    end
  end

  describe "Tools.divine_sense" do
    test "PC otro who error" do
      thane = paladin([])
      vex = paladin(name: "Vex")

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane, "Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Thane"), roller: fixed_roller(7)}}
      assert {:error, msg} = Tools.divine_sense(ctx, "Vex")
      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["Vex"].divine_sense_uses == 4
    end

    test "PC sí mismo" do
      thane = paladin([])

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane}),
          policy: :round_robin,
          participants: [p("Thane")]
        )

      assert {:ok, "Thane"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Thane"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.divine_sense(pc, "Thane")
      assert msg =~ "no percibe"
      assert Session.read_state(game).characters["Thane"].divine_sense_uses == 3
    end

    test "DM cualquiera" do
      thane = paladin([])

      game =
        start_session(
          world: World.new(characters: %{"Thane" => thane}),
          policy: :round_robin,
          participants: [p("dm"), p("Thane")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.divine_sense(dm, "Thane")
      assert msg =~ "Sentido divino"
      assert Session.read_state(game).characters["Thane"].divine_sense_uses == 3
    end
  end
end
