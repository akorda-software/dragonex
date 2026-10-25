defmodule Dragonex.ArcaneRecoveryTest do
  @moduledoc """
  Arcane Recovery 5e (D51): wizard restores expended slots greedily.
  Budget div(level+1, 2). No slot > 5. 1/long rest. Outside combat.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Games, Heroes, SpellSlots, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp wizard(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Lyra",
          class: "wizard",
          race: "elf",
          level: 1,
          hp: 7,
          max_hp: 7,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 16,
          wis: 12,
          cha: 10,
          side: "pc",
          arcane_recovery_used: false
        ],
        opts
      )
    )
  end

  defp fighter(opts) do
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
          side: "pc"
        ],
        opts
      )
    )
  end

  defp world(chars) do
    w =
      Enum.reduce(chars, World.new(), fn c, acc ->
        {:ok, acc} = World.add_character(c).(acc)
        acc
      end)

    World.init_spell_slots(w)
  end

  defp consume(w, who, level) do
    {:ok, w} = World.consume_slot(who, level).(w)
    w
  end

  describe "Actions.arcane_recovery/2" do
    test "wizard L1 budget 1 restaura un hueco de 1º" do
      w = world([wizard([])]) |> consume("Lyra", 1)

      assert w.spell_slots["Lyra"][1] == 1

      {:ok, msg, change} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "recupera 1 hueco de nivel 1"
      {:ok, w2} = change.(w)
      assert w2.spell_slots["Lyra"][1] == 2
      assert w2.characters["Lyra"].arcane_recovery_used == true
    end

    test "wizard L5 budget 3 greedy restaura un 3º" do
      w =
        world([wizard(level: 5)])
        |> consume("Lyra", 3)
        |> consume("Lyra", 1)

      max = SpellSlots.for_class("wizard", 5)
      assert w.spell_slots["Lyra"][3] == max[3] - 1
      assert w.spell_slots["Lyra"][1] == max[1] - 1

      {:ok, msg, change} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "1 hueco de nivel 3"
      refute msg =~ "nivel 1"
      {:ok, w2} = change.(w)
      assert w2.spell_slots["Lyra"][3] == max[3]
      assert w2.spell_slots["Lyra"][1] == max[1] - 1
      assert w2.characters["Lyra"].arcane_recovery_used == true
    end

    test "L5 greedy 2º + 1º cuando no hay 3º gastado" do
      w =
        world([wizard(level: 5)])
        |> consume("Lyra", 2)
        |> consume("Lyra", 1)

      {:ok, msg, change} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "1 hueco de nivel 2 y 1 de nivel 1"
      {:ok, w2} = change.(w)
      max = SpellSlots.for_class("wizard", 5)
      assert w2.spell_slots["Lyra"][2] == max[2]
      assert w2.spell_slots["Lyra"][1] == max[1]
    end

    test "no restaura ni marca used si no hay huecos gastados" do
      w = world([wizard([])])
      assert {:error, msg} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "no tiene huecos gastados"
      refute w.characters["Lyra"].arcane_recovery_used
      assert w.spell_slots["Lyra"][1] == 2
    end

    test "no mago" do
      w = world([fighter([])])
      assert {:error, msg} = Actions.arcane_recovery(w, "Thane")
      assert msg =~ "no es mago"
      refute w.characters["Thane"].arcane_recovery_used
    end

    test "who no existe" do
      assert {:error, msg} = Actions.arcane_recovery(World.new(), "ghost")
      assert msg =~ "no existe"
    end

    test "en combate error y no marca used" do
      w = world([wizard([])]) |> consume("Lyra", 1)
      w = %{w | phase: :combat}

      assert {:error, msg} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "combate"
      refute w.characters["Lyra"].arcane_recovery_used
      assert w.spell_slots["Lyra"][1] == 1
    end

    test "already used error y no restaura" do
      w = world([wizard(arcane_recovery_used: true)]) |> consume("Lyra", 1)
      assert {:error, msg} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "ya ha usado"
      assert w.spell_slots["Lyra"][1] == 1
      assert w.characters["Lyra"].arcane_recovery_used == true
    end

    test "no restaura huecos de nivel > 5" do
      w = world([wizard(level: 11)]) |> consume("Lyra", 6)
      assert w.spell_slots["Lyra"][6] == 0
      assert {:error, msg} = Actions.arcane_recovery(w, "Lyra")
      assert msg =~ "no tiene huecos gastados"
      refute w.characters["Lyra"].arcane_recovery_used
      assert w.spell_slots["Lyra"][6] == 0
    end
  end

  describe "validación de la recuperación preparada" do
    test "un mago caído, muerto o incapacitado no puede recuperar voluntariamente" do
      for opts <- [
            [hp: 0],
            [hp: 0, death_saves: %{successes: 0, fails: 3}],
            [conditions: ["incapacitated"]],
            [conditions: ["stunned"]],
            [conditions: ["paralyzed"]],
            [conditions: ["petrified"]],
            [conditions: ["unconscious"]]
          ] do
        w = world([wizard(opts)]) |> consume("Lyra", 1)
        assert {:error, _} = Actions.arcane_recovery(w, "Lyra")
      end
    end

    test "rechaza el cambio si el mago cae o queda incapacitado después de preparar" do
      w = world([wizard([])]) |> consume("Lyra", 1)
      assert {:ok, _, change} = Actions.arcane_recovery(w, "Lyra")
      {:ok, downed} = World.apply_damage("Lyra", 7).(w)
      {:ok, stunned} = World.apply_condition("Lyra", "stunned").(w)

      for current <- [downed, stunned] do
        assert {:error, _} = change.(current)
        assert current.spell_slots["Lyra"][1] == 1
        refute current.characters["Lyra"].arcane_recovery_used
      end
    end

    test "no sobrescribe una casilla gastada desde la preparación" do
      w = world([wizard([])]) |> consume("Lyra", 1)
      assert {:ok, _, change} = Actions.arcane_recovery(w, "Lyra")
      current = consume(w, "Lyra", 1)
      assert current.spell_slots["Lyra"][1] == 0
      assert {:error, _} = change.(current)
      refute current.characters["Lyra"].arcane_recovery_used
    end

    test "el mismo cambio no recupera otra vez aunque se vuelva al stock inicial" do
      w = world([wizard([])]) |> consume("Lyra", 1)
      assert {:ok, _, change} = Actions.arcane_recovery(w, "Lyra")
      assert {:ok, recovered} = change.(w)
      assert recovered.spell_slots["Lyra"][1] == 2
      assert recovered.characters["Lyra"].arcane_recovery_used
      assert {:error, _} = change.(recovered)

      current = consume(recovered, "Lyra", 1)
      assert current.spell_slots == w.spell_slots
      assert {:error, _} = change.(current)
    end

    test "entrar en combate o avanzar el tiempo invalida la recuperación preparada" do
      enemy = Character.new(name: "goblin", hp: 7, max_hp: 7, side: "enemy")
      w = world([wizard([]), enemy]) |> consume("Lyra", 1)
      assert {:ok, _, change} = Actions.arcane_recovery(w, "Lyra")
      assert {:ok, combat} = World.begin_combat(["Lyra", "goblin"]).(w)
      assert {:ok, later} = World.advance_time(60).(w)

      for current <- [combat, later] do
        assert {:error, _} = change.(current)
        assert current.spell_slots["Lyra"][1] == 1
        refute current.characters["Lyra"].arcane_recovery_used
      end
    end

    test "sigue disponible sin descanso previo y admite cambios de otro personaje" do
      w = world([wizard([]), fighter([])]) |> consume("Lyra", 1)
      assert {:ok, message, change} = Actions.arcane_recovery(w, "Lyra")
      assert {:ok, current} = World.apply_damage("Thane", 1).(w)
      assert {:ok, next} = change.(current)

      assert message =~ "recupera 1 hueco de nivel 1"
      assert next.spell_slots["Lyra"][1] == 2
      assert next.characters["Lyra"].arcane_recovery_used
      assert next.characters["Thane"] == current.characters["Thane"]
      assert next.characters["Lyra"].hp == w.characters["Lyra"].hp
      assert next.elapsed_seconds == w.elapsed_seconds
      assert next.rest_state == w.rest_state
      assert next.turn_state == w.turn_state
    end
  end

  describe "rest recarga" do
    test "short_rest NO recarga el flag" do
      w = world([wizard(hp: 5, max_hp: 7, arcane_recovery_used: true, con: 13)])
      {:ok, _, rest} = Actions.short_rest(w, "Lyra", Dragonex.Dice.always(4))
      {:ok, w} = rest.(w)
      assert w.characters["Lyra"].arcane_recovery_used == true
    end

    test "long_rest recarga el flag" do
      w = world([wizard(hp: 7, max_hp: 7, arcane_recovery_used: true)])
      {:ok, _, rest} = Actions.long_rest(w, "Lyra")
      {:ok, w} = rest.(w)
      assert w.characters["Lyra"].arcane_recovery_used == false
    end
  end

  describe "level-up / merge conservan el flag" do
    test "World.level_up no resetea el flag" do
      w = world([wizard(level: 1, arcane_recovery_used: true)])
      {:ok, w2} = World.level_up("Lyra", %{}).(w)
      assert w2.characters["Lyra"].level == 2
      assert w2.characters["Lyra"].arcane_recovery_used == true
    end

    test "Games.merge_character_level_up no pisa el flag vivo" do
      live = wizard(level: 1, arcane_recovery_used: true, hp: 4)
      sheet = %{live | level: 2, max_hp: 13, arcane_recovery_used: false}
      w = world([live])
      w2 = Games.merge_character_level_up(w, "Lyra", sheet)
      assert w2.characters["Lyra"].level == 2
      assert w2.characters["Lyra"].arcane_recovery_used == true
      assert w2.characters["Lyra"].hp == 4
    end
  end

  describe "Heroes.build" do
    test "wizard arranca con flag false" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lyra",
          race: "human",
          class: "wizard",
          background: "sage"
        })

      refute c.arcane_recovery_used
    end
  end

  describe "Codec" do
    test "flag true sobrevive" do
      c = wizard(arcane_recovery_used: true)
      w = world([c])
      again = Codec.decode(Codec.encode(w)).characters["Lyra"]
      assert again.arcane_recovery_used == true
    end

    test "jsonb viejo sin clave → false" do
      encoded =
        wizard([])
        |> Codec.encode_character()
        |> Map.drop(["arcane_recovery_used"])

      refute Map.has_key?(encoded, "arcane_recovery_used")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      refute decoded.arcane_recovery_used
    end
  end

  describe "Tools.arcane_recovery" do
    test "PC otro who error" do
      lyra = wizard([])
      vex = wizard(name: "Vex")
      w = World.init_spell_slots(World.new(characters: %{"Lyra" => lyra, "Vex" => vex}))
      w = %{w | spell_slots: Map.put(w.spell_slots, "Vex", %{1 => 1})}

      game =
        start_session(
          world: w,
          policy: :round_robin,
          participants: [p("dm"), p("Lyra"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Lyra"), roller: fixed_roller(7)}}
      assert {:error, msg} = Tools.arcane_recovery(ctx, "Vex")
      assert msg =~ "RECHAZADO"
      refute Session.read_state(game).characters["Vex"].arcane_recovery_used
    end

    test "PC sí mismo" do
      lyra = wizard([])
      w = World.init_spell_slots(World.new(characters: %{"Lyra" => lyra}))
      w = %{w | spell_slots: %{"Lyra" => %{1 => 1}}}

      game =
        start_session(
          world: w,
          policy: :round_robin,
          participants: [p("Lyra")]
        )

      assert {:ok, "Lyra"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Lyra"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.arcane_recovery(pc, "Lyra")
      assert msg =~ "1 hueco de nivel 1"
      assert Session.read_state(game).characters["Lyra"].arcane_recovery_used == true
      assert Session.read_state(game).spell_slots["Lyra"][1] == 2
    end

    test "DM cualquiera" do
      lyra = wizard([])
      w = World.init_spell_slots(World.new(characters: %{"Lyra" => lyra}))
      w = %{w | spell_slots: %{"Lyra" => %{1 => 1}}}

      game =
        start_session(
          world: w,
          policy: :round_robin,
          participants: [p("dm"), p("Lyra")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(7)}}
      assert {:ok, msg} = Tools.arcane_recovery(dm, "Lyra")
      assert msg =~ "1 hueco de nivel 1"
      assert Session.read_state(game).characters["Lyra"].arcane_recovery_used == true
    end
  end
end
