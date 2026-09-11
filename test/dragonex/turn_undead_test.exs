defmodule Dragonex.TurnUndeadTest do
  @moduledoc """
  Turn Undead 5e (D53): cleric L2+ spends Channel Divinity; living undead
  Wisdom-save vs DC or become frightened. Combat allowed. Short and long
  rest recharge. No Destroy Undead, no domain Channel, no grid.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Games, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp cleric(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Aldric",
          class: "cleric",
          race: "human",
          level: 2,
          hp: 16,
          max_hp: 16,
          ac: 16,
          str: 14,
          dex: 10,
          con: 14,
          wis: 16,
          side: "pc"
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
          level: 2,
          hp: 18,
          max_hp: 18,
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
          wis: 10,
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

  describe "Actions.turn_undead/3" do
    test "L2 clérigo gasta y asusta undead que falla" do
      w =
        world([
          cleric([]),
          monster(name: "Esqueleto", race: "Undead")
        ])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      assert msg ==
               "Aldric usa Expulsar no-muertos (CD 13): Esqueleto queda asustado (usos restantes 0)."

      {:ok, w2} = change.(w)
      assert w2.characters["Aldric"].channel_divinity_used == true
      assert World.has_condition?(w2, "Esqueleto", "frightened")
    end

    test "save éxito no asusta" do
      w =
        world([
          cleric([]),
          monster(name: "Esqueleto", race: "undead")
        ])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(20))

      assert msg ==
               "Aldric usa Expulsar no-muertos (CD 13): Esqueleto supera la salvación (usos restantes 0)."

      {:ok, w2} = change.(w)
      assert w2.characters["Aldric"].channel_divinity_used == true
      refute World.has_condition?(w2, "Esqueleto", "frightened")
    end

    test "goblin humanoid ignorado" do
      w =
        world([
          cleric([]),
          monster(name: "Goblin", race: "humanoid"),
          monster(name: "Esqueleto", race: "undead")
        ])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      refute msg =~ "Goblin"
      assert msg =~ "Esqueleto queda asustado"
      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Goblin", "frightened")
      assert World.has_condition?(w2, "Esqueleto", "frightened")
    end

    test "hp ≤ 0 ignorado" do
      w =
        world([
          cleric([]),
          monster(name: "Esqueleto", race: "undead", hp: 0),
          monster(name: "Zombi", race: "undead", hp: 8, max_hp: 8)
        ])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      refute msg =~ "Esqueleto"
      assert msg =~ "Zombi queda asustado"
      {:ok, w2} = change.(w)
      refute World.has_condition?(w2, "Esqueleto", "frightened")
      assert World.has_condition?(w2, "Zombi", "frightened")
    end

    test "L1 error no gasta" do
      w = world([cleric(level: 1), monster(name: "Esqueleto", race: "undead")])
      assert {:error, msg} = Actions.turn_undead(w, "Aldric", fixed(1))
      assert msg =~ "nivel 2"
      refute w.characters["Aldric"].channel_divinity_used
    end

    test "no clérigo error" do
      w = world([fighter([])])
      assert {:error, msg} = Actions.turn_undead(w, "Rhogar", fixed(1))
      assert msg =~ "no es clérigo"
    end

    test "already used error" do
      w = world([cleric([]), monster(name: "Esqueleto", race: "undead")])
      {:ok, _, change} = Actions.turn_undead(w, "Aldric", fixed(1))
      {:ok, w} = change.(w)

      assert {:error, msg} = Actions.turn_undead(w, "Aldric", fixed(1))
      assert msg =~ "ya ha usado"
    end

    test "vacío gasta" do
      w = world([cleric([]), monster([])])

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))

      assert msg ==
               "Aldric usa Expulsar no-muertos (CD 13) y no hay no-muertos que Expulsar no-muertos pueda afectar (usos restantes 0)."

      {:ok, w2} = change.(w)
      assert w2.characters["Aldric"].channel_divinity_used == true
    end

    test "who no existe" do
      assert {:error, msg} = Actions.turn_undead(World.new(), "ghost", fixed(1))
      assert msg =~ "no existe"
    end

    test "permitido en combate" do
      w = %{world([cleric([]), monster(name: "Esqueleto", race: "undead")]) | phase: :combat}

      {:ok, msg, change} = Actions.turn_undead(w, "Aldric", fixed(1))
      assert msg =~ "Esqueleto queda asustado"
      {:ok, w2} = change.(w)
      assert w2.characters["Aldric"].channel_divinity_used == true
    end
  end

  describe "rest recarga" do
    test "short_rest recarga" do
      w = world([cleric(hp: 10, max_hp: 16, channel_divinity_used: true, con: 14)])
      {:ok, _, rest} = Actions.short_rest(w, "Aldric", fixed(4))
      {:ok, w} = rest.(w)
      assert w.characters["Aldric"].channel_divinity_used == false

      {:ok, _, change} = Actions.turn_undead(w, "Aldric", fixed(1))
      {:ok, w} = change.(w)
      assert w.characters["Aldric"].channel_divinity_used == true
    end

    test "long_rest recarga" do
      w = world([cleric(hp: 16, max_hp: 16, channel_divinity_used: true)])
      {:ok, _, rest} = Actions.long_rest(w, "Aldric")
      {:ok, w} = rest.(w)
      assert w.characters["Aldric"].channel_divinity_used == false
    end
  end

  describe "level-up / merge conservan el flag" do
    test "World.level_up no resetea el flag" do
      w = world([cleric(level: 2, channel_divinity_used: true)])
      {:ok, w2} = World.level_up("Aldric", %{}).(w)
      assert w2.characters["Aldric"].level == 3
      assert w2.characters["Aldric"].channel_divinity_used == true
    end

    test "Games.merge_character_level_up no pisa el flag vivo" do
      live = cleric(level: 2, channel_divinity_used: true, hp: 4)
      sheet = %{live | level: 3, max_hp: 24, channel_divinity_used: false}
      w = world([live])
      w2 = Games.merge_character_level_up(w, "Aldric", sheet)
      assert w2.characters["Aldric"].level == 3
      assert w2.characters["Aldric"].channel_divinity_used == true
      assert w2.characters["Aldric"].hp == 4
    end
  end

  describe "Codec" do
    test "channel_divinity_used survives" do
      c = cleric(channel_divinity_used: true)
      w = world([c])
      assert Codec.decode(Codec.encode(w)).characters["Aldric"].channel_divinity_used == true
    end

    test "absent in old jsonb is false" do
      encoded = cleric([]) |> Codec.encode_character() |> Map.delete("channel_divinity_used")
      refute Map.has_key?(encoded, "channel_divinity_used")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.channel_divinity_used == false
    end
  end

  describe "Tools.turn_undead" do
    test "PC otro who error" do
      aldric = cleric([])
      vex = cleric(name: "Vex")

      game =
        start_session(
          world: World.new(characters: %{"Aldric" => aldric, "Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Aldric"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Aldric"), roller: fixed_roller(1)}}
      assert {:error, msg} = Tools.turn_undead(ctx, "Vex")
      assert msg =~ "RECHAZADO"
      refute Session.read_state(game).characters["Vex"].channel_divinity_used
    end

    test "PC sí mismo" do
      aldric = cleric([])

      game =
        start_session(
          world: World.new(characters: %{"Aldric" => aldric}),
          policy: :round_robin,
          participants: [p("Aldric")]
        )

      assert {:ok, "Aldric"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Aldric"), roller: fixed_roller(1)}}
      assert {:ok, msg} = Tools.turn_undead(pc, "Aldric")
      assert msg =~ "no hay no-muertos"
      assert Session.read_state(game).characters["Aldric"].channel_divinity_used == true
    end

    test "DM cualquiera" do
      aldric = cleric([])
      skeleton = monster(name: "Esqueleto", race: "undead")

      game =
        start_session(
          world: World.new(characters: %{"Aldric" => aldric, "Esqueleto" => skeleton}),
          policy: :round_robin,
          participants: [p("dm"), p("Aldric")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(1)}}
      assert {:ok, msg} = Tools.turn_undead(dm, "Aldric")
      assert msg =~ "Esqueleto queda asustado"
      state = Session.read_state(game)
      assert state.characters["Aldric"].channel_divinity_used == true
      assert World.has_condition?(state, "Esqueleto", "frightened")
    end
  end
end
