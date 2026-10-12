defmodule Dragonex.BardicInspirationTest do
  @moduledoc """
  Bardic Inspiration 5e (D50): bard spends uses to grant inspired d6.
  First attack/check/save/death save consumes. No colleges. Always d6.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, Spell, Tools, Weapon, World}
  alias ExAgent.{Session, Session.SharedState}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp rapier do
    %Weapon{
      name: "rapier",
      dice: "1d8",
      damage_type: "piercing",
      attack_ability: :dex,
      finesse: true
    }
  end

  defp longsword do
    %Weapon{
      name: "longsword",
      dice: "1d8",
      damage_type: "slashing",
      attack_ability: :str
    }
  end

  defp bard(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Lira",
          class: "bard",
          race: "human",
          level: 1,
          hp: 10,
          max_hp: 10,
          ac: 13,
          str: 8,
          dex: 14,
          con: 12,
          int: 10,
          wis: 10,
          cha: 16,
          side: "pc",
          bardic_inspiration_uses: 3,
          inspired: false,
          weapons: [rapier()]
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
          hp: 12,
          max_hp: 12,
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

  defp goblin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "goblin",
          class: "monster",
          race: "goblinoid",
          hp: 40,
          max_hp: 40,
          ac: 12,
          dex: 10,
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

  describe "Actions.bardic_inspiration/3" do
    test "bardo inspira a un aliado y gasta 1 uso" do
      w = world([bard([]), ally([])])

      {:ok, msg, change} = Actions.bardic_inspiration(w, "Lira", "Thane")

      assert msg =~ "Lira inspira a Thane"
      assert msg =~ "usos restantes 2"
      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].inspired == true
      assert w2.characters["Lira"].bardic_inspiration_uses == 2
      refute w2.characters["Lira"].inspired
    end

    test "puede inspirarse a sí mismo" do
      w = world([bard([])])

      {:ok, msg, change} = Actions.bardic_inspiration(w, "Lira", "Lira")

      assert msg =~ "inspira a Lira"
      {:ok, w2} = change.(w)
      assert w2.characters["Lira"].inspired == true
      assert w2.characters["Lira"].bardic_inspiration_uses == 2
    end

    test "who no existe" do
      assert {:error, msg} = Actions.bardic_inspiration(World.new(), "ghost", "ghost")
      assert msg =~ "no existe"
    end

    test "target no existe" do
      w = world([bard([])])
      assert {:error, msg} = Actions.bardic_inspiration(w, "Lira", "ghost")
      assert msg =~ "no existe"
      assert w.characters["Lira"].bardic_inspiration_uses == 3
    end

    test "no bard error" do
      w = world([ally([])])
      assert {:error, msg} = Actions.bardic_inspiration(w, "Thane", "Thane")
      assert msg =~ "no es bardo"
    end

    test "0 uses error no gasta" do
      w = world([bard(bardic_inspiration_uses: 0), ally([])])
      assert {:error, msg} = Actions.bardic_inspiration(w, "Lira", "Thane")
      assert msg =~ "no tiene usos"
      refute w.characters["Thane"].inspired
    end

    test "ya inspired no stack ni refresh" do
      w = world([bard([]), ally(inspired: true)])
      assert {:error, msg} = Actions.bardic_inspiration(w, "Lira", "Thane")
      assert msg =~ "ya está inspirado"
      assert w.characters["Lira"].bardic_inspiration_uses == 3
    end
  end

  describe "World.spend_bardic/2" do
    test "resta uso y marca inspired" do
      w = world([bard([]), ally([])])
      {:ok, w2} = World.spend_bardic("Lira", "Thane").(w)
      assert w2.characters["Thane"].inspired
      assert w2.characters["Lira"].bardic_inspiration_uses == 2
    end

    test "no bard error" do
      w = world([ally([])])
      assert {:error, msg} = World.spend_bardic("Thane", "Thane").(w)
      assert msg =~ "no es bardo"
    end
  end

  describe "Actions.attack consume primer swing" do
    test "suma 1d6 al total del primer swing y consume inspired" do
      w = world([bard(inspired: true), goblin([])])

      # dex 2 + prof 2. d20=10 → 14; +d6=5 → 19 vs CA 12; d8=4 +2 = 6.
      assert {:ok, msg, change} =
               Actions.attack(w, "Lira", "goblin", "rapier", seq([10, 5, 4, 99]))

      assert msg =~ "acierta"
      assert msg =~ "ataque: incluye 5 inspiración"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 6
      refute w2.characters["Lira"].inspired
      assert Process.get(:seq) == [99]
    end

    test "miss consume el d6; no suma al daño" do
      w = world([bard(inspired: true), goblin(ac: 30)])

      assert {:ok, msg, change} = Actions.attack(w, "Lira", "goblin", "rapier", seq([2, 3, 99]))

      assert msg =~ "fallo"
      assert msg =~ "ataque: incluye 3 inspiración"
      refute msg =~ "daño"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40
      refute w2.characters["Lira"].inspired
      assert Process.get(:seq) == [99]
    end

    test "Extra Attack: solo el primer swing gasta" do
      fighter = ally(level: 5, inspired: true, hp: 40, max_hp: 40)
      w = world([fighter, goblin([])])

      # swing1: d20=10 +d6=4; d8=4. swing2: d20=10; d8=4. sentinel 99.
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([10, 4, 4, 10, 4, 99]))

      assert msg =~ "2 golpes"
      assert msg =~ "ataque: incluye 4 inspiración"
      {:ok, w2} = change.(w)
      refute w2.characters["Thane"].inspired
      assert Process.get(:seq) == [99]
    end
  end

  describe "Actions.check" do
    test "1d6 al total del chequeo y consume inspired" do
      w = world([bard(inspired: true)])

      # cha 3. d20=10 → 13; +d6=4 → 17 vs CD 15 éxito.
      {:ok, msg, change} = Actions.check(w, "Lira", :cha, 15, false, seq([10, 4]))

      assert msg =~ "éxito"
      assert msg =~ "4 (inspiración)"
      {:ok, w2} = change.(w)
      refute w2.characters["Lira"].inspired
    end
  end

  describe "Actions.spell save" do
    test "1d6 al total de la salvación del inspirado" do
      caster =
        Character.new(
          name: "Lyra",
          class: "wizard",
          level: 1,
          hp: 7,
          max_hp: 7,
          ac: 12,
          int: 16,
          side: "pc",
          spells: [
            %Spell{
              name: "acid splash",
              level: 0,
              kind: :save,
              casting_ability: :int,
              save_ability: :dex,
              dice: "1d6",
              damage_type: "acid"
            }
          ]
        )

      target = goblin(inspired: true, hp: 20, max_hp: 20)
      w = world([caster, target])

      # DC 13. d20=10 +0 = 10 fail; +d6=4 → 14 éxito; daño 6 → 3.
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "acid splash", "goblin", seq([10, 4, 6]))

      assert msg =~ "supera la salvación"
      assert msg =~ "+4 inspiración"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 17
      refute w2.characters["goblin"].inspired
    end
  end

  describe "Actions.death_save" do
    test "1d6 al d20 y consume inspired" do
      w = world([bard(hp: 0, inspired: true)])

      {:ok, msg, change} = Actions.death_save(w, "Lira", seq([8, 3]))

      assert msg =~ "éxito"
      assert msg =~ "+3 inspiración"
      {:ok, w2} = change.(w)
      assert w2.characters["Lira"].death_saves.successes == 1
      refute w2.characters["Lira"].inspired
    end
  end

  describe "rest recarga" do
    test "short_rest NO recarga usos ni quita inspired" do
      w = world([bard(hp: 8, max_hp: 10, bardic_inspiration_uses: 1, inspired: true, con: 12)])
      {:ok, _, rest} = Actions.short_rest(w, "Lira", Dragonex.Dice.always(4))
      {:ok, w} = rest.(w)
      assert w.characters["Lira"].bardic_inspiration_uses == 1
      assert w.characters["Lira"].inspired == true
    end

    test "long_rest recarga usos del bardo a max(1, cha_mod) y quita inspired" do
      w = world([bard(hp: 10, max_hp: 10, bardic_inspiration_uses: 0, inspired: true, cha: 16)])
      {:ok, _, rest} = Actions.long_rest(w, "Lira")
      {:ok, w} = rest.(w)
      assert w.characters["Lira"].bardic_inspiration_uses == 3
      refute w.characters["Lira"].inspired
    end

    test "long_rest de no bardo pone inspired false y deja uses 0" do
      w = world([ally(hp: 12, max_hp: 12, inspired: true)])
      {:ok, _, rest} = Actions.long_rest(w, "Thane")
      {:ok, w} = rest.(w)
      assert w.characters["Thane"].bardic_inspiration_uses == 0
      refute w.characters["Thane"].inspired
    end
  end

  describe "level-up / merge conservan uses e inspired" do
    test "World.level_up no resetea uses ni inspired" do
      w = world([bard(level: 1, bardic_inspiration_uses: 1, inspired: true)])
      {:ok, w2} = World.level_up("Lira", %{}).(w)
      assert w2.characters["Lira"].level == 2
      assert w2.characters["Lira"].bardic_inspiration_uses == 1
      assert w2.characters["Lira"].inspired == true
    end

    test "Games.merge_character_level_up no pisa uses ni inspired vivos" do
      live = bard(level: 1, bardic_inspiration_uses: 1, inspired: true, hp: 4)
      sheet = %{live | level: 2, max_hp: 16, bardic_inspiration_uses: 3, inspired: false}
      w = world([live])
      w2 = Games.merge_character_level_up(w, "Lira", sheet)
      assert w2.characters["Lira"].level == 2
      assert w2.characters["Lira"].bardic_inspiration_uses == 1
      assert w2.characters["Lira"].inspired == true
      assert w2.characters["Lira"].hp == 4
    end
  end

  describe "Heroes.build CHA" do
    test "bard CHA 8 → 1 uso" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lira",
          race: "elf",
          subrace: "wood elf",
          class: "bard",
          background: "entertainer",
          scores: %{str: 10, dex: 14, con: 13, int: 12, wis: 10, cha: 8}
        })

      assert c.cha == 8
      assert c.bardic_inspiration_uses == 1
      refute c.inspired
    end

    test "bard CHA 16 → 3 usos" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lira",
          race: "human",
          class: "bard",
          background: "entertainer",
          scores: %{str: 8, dex: 14, con: 13, int: 10, wis: 10, cha: 15}
        })

      assert c.cha == 16
      assert c.bardic_inspiration_uses == 3
    end

    test "no bard uses 0" do
      {:ok, c} =
        Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

      assert c.bardic_inspiration_uses == 0
      refute c.inspired
    end
  end

  describe "Codec" do
    test "uses e inspired overviven" do
      c = bard(bardic_inspiration_uses: 2, inspired: true)
      w = world([c])
      again = Codec.decode(Codec.encode(w)).characters["Lira"]
      assert again.bardic_inspiration_uses == 2
      assert again.inspired == true
    end

    test "jsonb viejo sin claves → 0 / false" do
      encoded =
        bard([])
        |> Codec.encode_character()
        |> Map.drop(["bardic_inspiration_uses", "inspired"])

      refute Map.has_key?(encoded, "bardic_inspiration_uses")
      refute Map.has_key?(encoded, "inspired")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.bardic_inspiration_uses == 0
      refute decoded.inspired
    end
  end

  describe "Tools.bardic_inspiration" do
    test "PC otro who error" do
      lira = bard([])
      vex = bard(name: "Vex")

      game =
        start_session(
          world: World.new(characters: %{"Lira" => lira, "Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Lira"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Lira"), roller: fixed_roller(7)}}
      assert {:error, msg} = Tools.bardic_inspiration(ctx, "Vex", "Lira")
      assert msg =~ "RECHAZADO"
      assert Session.read_state(game).characters["Vex"].bardic_inspiration_uses == 3
      refute Session.read_state(game).characters["Lira"].inspired
    end

    test "PC sí mismo puede inspirar aliado" do
      lira = bard([])
      thane = ally([])

      game =
        start_session(
          world: World.new(characters: %{"Lira" => lira, "Thane" => thane}),
          policy: :round_robin,
          participants: [p("Lira"), p("Thane")]
        )

      assert {:ok, "Lira"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Lira"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.bardic_inspiration(pc, "Lira", "Thane")
      assert msg =~ "inspira a Thane"
      assert Session.read_state(game).characters["Thane"].inspired
      assert Session.read_state(game).characters["Lira"].bardic_inspiration_uses == 2
    end

    test "DM cualquiera" do
      lira = bard([])

      game =
        start_session(
          world: World.new(characters: %{"Lira" => lira}),
          policy: :round_robin,
          participants: [p("dm"), p("Lira")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.bardic_inspiration(dm, "Lira", "Lira")
      assert msg =~ "inspira a Lira"
      assert Session.read_state(game).characters["Lira"].inspired
      assert Session.read_state(game).characters["Lira"].bardic_inspiration_uses == 2
    end
  end
end
