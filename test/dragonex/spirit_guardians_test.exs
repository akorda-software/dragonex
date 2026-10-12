defmodule Dragonex.SpiritGuardiansTest do
  use ExUnit.Case, async: true

  @moduledoc """
  D99 Spirit Guardians: sin daño inmediato al lanzar; el aura tickea al
  inicio del turno nuevo del lanzador mientras concentra — cada enemigo
  vivo y consciente tira SAB vs la CD guardada (stack completo de
  condition_save); fallo = dados completos radiante, éxito = mitad floor.
  Oráculos con dados inyectados y conteo exacto por enemigo.
  """

  alias Dragonex.{Actions, Character, Codec, World}
  alias Dragonex.Heroes.Spells

  defp seq(values) do
    Process.put(:sg_rolls, values)

    fn sides ->
      [value | rest] = Process.get(:sg_rolls)
      assert value in 1..sides
      Process.put(:sg_rolls, rest)
      value
    end
  end

  defp spent?, do: Process.get(:sg_rolls, [])
  defp no_roll(_), do: flunk("no debía tirar")

  # Clériga L5 (competencia 3), SAB 16 → CD 14. Casillas L5: 1:4 2:3 3:2 4:1 5:1.
  defp cleric(opts \\ []) do
    spell = Spells.to_character_spell(Spells.get("spirit guardians"), :wis)

    Character.new(
      Keyword.merge(
        [
          name: "Cora",
          class: "cleric",
          level: 5,
          hp: 30,
          max_hp: 30,
          wis: 16,
          ac: 14,
          side: "pc",
          spells: [spell]
        ],
        opts
      )
    )
  end

  defp foe(name, opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: name, class: "monster", hp: 30, max_hp: 30, ac: 12, wis: 8, side: "enemy"],
        opts
      )
    )
  end

  defp world(chars) do
    chars
    |> Enum.reduce(World.new(phase: :combat), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  defp turn!(w, name, roller \\ nil) do
    {:ok, w} = World.set_current_combatant(name, "main", roller || (&Dragonex.Dice.roll/1)).(w)
    w
  end

  defp cast!(w, roller, cast_level \\ nil) do
    assert {:ok, msg, change} =
             Actions.spell(w, "Cora", "spirit guardians", "Goblin", roller, nil, cast_level)

    assert {:ok, next} = change.(w)
    {msg, next}
  end

  defp aura(w, name \\ "Cora") do
    Enum.find(w.characters[name].conditions, fn
      %{"condition" => "spirit_guardians"} -> true
      _ -> false
    end)
  end

  test "al lanzar NO hay daño ni salvación: marca el aura, concentra y gasta casilla 3º" do
    w = world([cleric(), foe("Goblin")])
    w = turn!(w, "Cora")

    # D99: la lanzadura no tira NINGÚN dado.
    {msg, next} = cast!(w, seq([]))

    assert msg =~ "conjura Guardianes espirituales"
    assert msg =~ "CD 14"
    assert msg =~ "concentra en Guardianes espirituales"

    entry = aura(next)
    assert entry["source"] == "spirit_guardians:Cora"
    assert entry["dice"] == "3d8"
    assert entry["dc"] == 14

    assert next.characters["Goblin"].hp == 30
    assert next.characters["Cora"].concentrating == "spirit guardians"
    assert next.spell_slots["Cora"][3] == 1
    assert spent?() == []
  end

  test "primer tick en el turno nuevo: fallo = 3d8 completos; éxito = mitad floor" do
    w = world([cleric(), foe("Goblin", wis: 16)])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, seq([]))

    # Goblin (SAB 16, mod +3): d20 11 → 14 ≥ 14... justo. Usamos 12 → 15 ≥ 14 éxito.
    # d20 12 (15 vs CD 14) éxito; 3d8 = 2+2+2 = 6 → mitad 3.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([12, 2, 2, 2]))

    assert w.characters["Goblin"].hp == 30 - 3

    notes = w.log |> Enum.map(&elem(&1, 1)) |> Enum.join(" ")
    assert notes =~ "supera la salvación de Sabiduría de spirit guardians"
    assert spent?() == []

    # Segundo tick: fallo (d20 5 → 8 < 14) → 3d8 = 4+4+4 = 12 completos.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([5, 4, 4, 4]))
    assert w.characters["Goblin"].hp == 30 - 3 - 12
    assert w.log |> Enum.map(&elem(&1, 1)) |> Enum.join(" ") =~ "falla la salvación"
    assert spent?() == []
  end

  test "tick multi-enemigo en orden de nombre: un conjunto de dados por enemigo" do
    w = world([cleric(), foe("Kobold"), foe("Goblin", wis: 16)])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, seq([]))

    # Orden alfabético: Goblin primero (éxito, mitad), Kobold después (fallo).
    # Goblin: d20 12 (15 ≥ 14) + 3d8(1,1,1)=3 → 1. Kobold: d20 5 (4 < 14) + 3d8(4,4,4)=12.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([12, 1, 1, 1, 5, 4, 4, 4]))

    assert w.characters["Goblin"].hp == 30 - 1
    assert w.characters["Kobold"].hp == 30 - 12
    assert spent?() == []
  end

  test "el daño del tick puede romper la concentración del enemigo dañado" do
    shaman =
      foe("Goblin",
        con: 10,
        concentrating: "bless",
        conditions: [
          %{"condition" => "blessed", "source" => "Goblin", "concentration" => "bless"}
        ]
      )

    w = world([cleric(), shaman])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, seq([]))

    # Goblin (bendecido): la salvación SAB del tick consume el d4 de bless
    # (d20 6 + d4 2 - 1 = 7 < 14, fallo); daño 3d8 = 15; su salvación de
    # CONCENTRACIÓN vs CD 10 también suma bless (d20 4 + d4 2 + 0 = 6 < 10)
    # → pierde bless y su condición se limpia.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([6, 2, 5, 5, 5, 4, 2]))

    assert w.characters["Goblin"].hp == 30 - 15
    assert w.characters["Goblin"].concentrating == nil
    assert w.characters["Goblin"].conditions == []
    assert spent?() == []
  end

  test "sin concentración no tickea y la marca muere por las rutas D85" do
    for route <- [:drop, :zero, :rage, :incap, :clock] do
      w = world([cleric(), foe("Goblin")])
      w = turn!(w, "Cora")
      {_msg, w} = cast!(w, seq([]))
      assert aura(w) != nil

      {:ok, w} =
        case route do
          :drop -> World.clear_concentration("Cora").(w)
          :zero -> World.apply_damage("Cora", 99).(w)
          :rage -> World.set_raging("Cora", true).(w)
          :incap -> World.apply_condition("Cora", "incapacitated").(w)
          :clock -> World.advance_time(600).(%{w | phase: :exploration})
        end

      assert aura(w) == nil, "#{route}"
      assert w.characters["Cora"].concentrating == nil, "#{route}"

      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Cora", &no_roll/1)
      assert w.characters["Goblin"].hp == 30, "#{route}"
    end
  end

  test "la salvación del aura consume Inspiración aunque el daño sea inmune" do
    target = foe("Goblin", inspired: true, damage_immunities: ["radiant"])
    w = world([cleric(), target]) |> turn!("Cora")
    {_msg, w} = cast!(w, seq([]))
    {:ok, w} = World.next_round().(w)

    w = turn!(w, "Cora", seq([8, 6, 2, 2, 2]))

    refute w.characters["Goblin"].inspired
    assert w.characters["Goblin"].hp == 30
    assert spent?() == []
  end

  test "la salvación del aura consume Indomitable y no lo devuelve al siguiente tick" do
    target = foe("Goblin", class: "fighter", level: 9, wis: 10)
    w = world([cleric(), target]) |> turn!("Cora")
    {_msg, w} = cast!(w, seq([]))
    {:ok, w} = World.next_round().(w)

    w = turn!(w, "Cora", seq([2, 18, 2, 2, 2]))

    assert w.characters["Goblin"].indomitable_used
    assert w.characters["Goblin"].hp == 27
    assert spent?() == []

    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([2, 2, 2, 2]))
    assert w.characters["Goblin"].hp == 21
    assert spent?() == []
  end

  test "Inspiración gastada contra el aura no se reutiliza en concentración" do
    target = foe("Goblin", inspired: true, concentrating: "bless", con: 10)
    w = world([cleric(), target]) |> turn!("Cora")
    {_msg, w} = cast!(w, seq([]))
    {:ok, w} = World.next_round().(w)

    # SAB: 15 - 1 + 6; daño: 6 / 2; concentración: 3, sin otro d6.
    w = turn!(w, "Cora", seq([15, 6, 2, 2, 2, 3]))

    assert w.characters["Goblin"].hp == 27
    refute w.characters["Goblin"].inspired
    assert w.characters["Goblin"].concentrating == nil
    assert spent?() == []
  end

  test "Indomitable gastado contra el aura no se reutiliza en concentración" do
    target =
      foe("Goblin", class: "fighter", level: 9, wis: 10, con: 10, concentrating: "bless")

    w = world([cleric(), target]) |> turn!("Cora")
    {_msg, w} = cast!(w, seq([]))
    {:ok, w} = World.next_round().(w)

    # SAB: 2 → 18; daño: 6 / 2; concentración: 3, sin otra repetición.
    w = turn!(w, "Cora", seq([2, 18, 2, 2, 2, 3]))

    assert w.characters["Goblin"].hp == 27
    assert w.characters["Goblin"].indomitable_used
    assert w.characters["Goblin"].concentrating == nil
    assert spent?() == []
  end

  test "enemigos caídos, muertos e inconscientes quedan fuera del tick" do
    sleeper = foe("Goblin", conditions: [%{"condition" => "unconscious", "source" => "otro"}])
    downed = foe("Hurt", hp: 0)
    dead = foe("Zed", death_saves: %{successes: 0, fails: 3})

    w = world([cleric(), sleeper, downed, dead])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, seq([]))

    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", &no_roll/1)

    assert w.characters["Goblin"].hp == 30
    assert w.characters["Hurt"].hp == 0
    assert w.characters["Zed"].death_saves.fails == 3
  end

  test "upcast a 4º: el tick tira 4d8 por enemigo" do
    # L9 (competencia 4): CD 15 y casillas de 4º disponibles.
    w = world([cleric(level: 9), foe("Goblin")])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, seq([]), 4)
    assert aura(w)["dice"] == "4d8"
    assert aura(w)["dc"] == 15
    assert w.spell_slots["Cora"][4] == 2

    # Fallo (d20 5 - 1 = 4 < 15): 4d8 = 2+2+2+2 = 8.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([5, 2, 2, 2, 2]))
    assert w.characters["Goblin"].hp == 30 - 8
    assert spent?() == []
  end

  test "Twinned armado no aplica ni consume (alcance self, criterio D96)" do
    w = world([cleric(), foe("Goblin"), foe("Kobold")])
    {:ok, w} = World.set_metamagic("Cora", %{option: "twinned", target: "Kobold"}).(w)
    w = turn!(w, "Cora")

    {msg, next} = cast!(w, seq([]))
    refute msg =~ "Twinned"
    assert next.characters["Cora"].metamagic == %{option: "twinned", target: "Kobold"}
    assert aura(next) != nil
  end

  test "Codec conserva la marca con fuente, dados y CD" do
    w = world([cleric(level: 9), foe("Goblin")])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, seq([]), 4)

    again = Codec.decode(Codec.encode(w))

    entry =
      Enum.find(
        again.characters["Cora"].conditions,
        &match?(%{"condition" => "spirit_guardians"}, &1)
      )

    assert entry["source"] == "spirit_guardians:Cora"
    assert entry["dice"] == "4d8"
    assert entry["dc"] == 15
    assert again.characters["Cora"].concentrating == "spirit guardians"
  end

  test "sin casilla de 3º: error sin mutar" do
    w = world([cleric(), foe("Goblin")])
    w = turn!(w, "Cora")
    w = %{w | spell_slots: Map.put(w.spell_slots, "Cora", %{1 => 4, 2 => 3})}

    assert {:error, msg} = Actions.spell(w, "Cora", "spirit guardians", "Goblin", seq([]), nil)
    assert msg =~ "casillas"
    assert aura(w) == nil
    assert w.characters["Goblin"].hp == 30
  end

  test "re-selección, reacción y Codec no duplican los grupos del inicio de turno" do
    alias Dragonex.RollLog

    w = world([cleric(), foe("Goblin")]) |> turn!("Cora")
    {_msg, w} = cast!(w, seq([]))
    {:ok, w} = World.next_round().(w)
    {:ok, recorder} = RollLog.start()
    on_exit(fn -> if Process.alive?(recorder), do: RollLog.stop(recorder) end)
    roller = seq([5, 2, 2, 2])
    log = %RollLog{base: roller, recorder: recorder}

    {:ok, w} = World.set_current_combatant("Cora", "main", roller, log).(w)
    assert w.characters["Goblin"].hp == 24
    assert [%{kind: :save}, %{kind: :damage}] = entries = RollLog.entries(recorder)
    assert spent?() == []

    # An exhausted roller also catches accidental, unlogged repeats.
    {:ok, same} = World.set_current_combatant("Cora", "main", roller, log).(w)
    {:ok, reaction} = World.set_current_combatant("Cora", "reaction", roller, log).(same)
    loaded = reaction |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    {:ok, restored} = World.set_current_combatant("Cora", "main", roller, log).(loaded)

    assert restored.characters["Goblin"].hp == 24
    assert RollLog.entries(recorder) == entries
  end
end
