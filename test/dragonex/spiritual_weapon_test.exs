defmodule Dragonex.SpiritualWeaponTest do
  use ExUnit.Case, async: true

  @moduledoc """
  D99 Spiritual Weapon persistente: la lanzadura deja una postura
  (rounds_left 10, sin concentración) y la nueva acción de bonus
  `spiritual_weapon_attack` repite el ataque de conjuro por el pipeline
  existente. Oráculos con dados inyectados y conteo exacto.
  """

  alias Dragonex.{Actions, Character, Codec, World}
  alias Dragonex.Heroes.Spells

  defp seq(values) do
    Process.put(:sw_rolls, values)

    fn sides ->
      [value | rest] = Process.get(:sw_rolls)
      assert value in 1..sides
      Process.put(:sw_rolls, rest)
      value
    end
  end

  defp spent?, do: Process.get(:sw_rolls, [])
  defp no_roll(_), do: flunk("no debía tirar")

  # Clériga L5 (competencia 3), SAB 16 (mod 3). Bonificador de ataque de
  # conjuro +6. Casillas L5: 1:4 2:3 3:2 4:1 5:1.
  defp cleric(opts \\ []) do
    spell = Spells.to_character_spell(Spells.get("spiritual weapon"), :wis)

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

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: "Goblin", class: "monster", hp: 30, max_hp: 30, ac: 12, wis: 8, side: "enemy"],
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

  defp cast!(w, target, roller, cast_level \\ nil) do
    assert {:ok, msg, change} =
             Actions.spell(w, "Cora", "spiritual weapon", target, roller, nil, cast_level)

    assert {:ok, next} = change.(w)
    {msg, next}
  end

  defp posture(w, name \\ "Cora") do
    Enum.find(w.characters[name].conditions, fn
      %{"condition" => "spiritual_weapon"} -> true
      _ -> false
    end)
  end

  test "la lanzadura deja la postura (dados escalados, mod, 10 rondas) sin concentración" do
    w = world([cleric(), goblin()])
    w = turn!(w, "Cora")

    # Ataque inicial: d20 15 (+6 = 21 vs CA 12) y 1d8 = 6 SIN mod (simplificación).
    {msg, next} = cast!(w, "Goblin", seq([15, 6]))

    assert msg =~ "conjura Arma espiritual"
    assert msg =~ "21 vs CA 12"
    assert msg =~ "6 de daño de fuerza"
    assert msg =~ "acompañará"

    entry = posture(next)
    assert entry["dice"] == "1d8"
    assert entry["mod"] == 3
    assert entry["rounds_left"] == 10

    assert next.characters["Cora"].concentrating == nil
    assert next.spell_slots["Cora"][2] == 2
    assert spent?() == []
  end

  test "upcast a 4º guarda 2d8 en la postura y gasta la casilla 4º" do
    # L9 para tener casillas de 4º (3 tras el gasto).
    w = world([cleric(level: 9), goblin()])
    w = turn!(w, "Cora")
    {_msg, next} = cast!(w, "Goblin", seq([15, 6, 2]), 4)

    assert posture(next)["dice"] == "2d8"
    assert next.spell_slots["Cora"][4] == 2
    assert spent?() == []
  end

  test "el golpe de bonus ataca 1d8+mod por el pipeline y no gasta casilla" do
    w = world([cleric(), goblin()])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, "Goblin", seq([15, 6]))

    # Turno nuevo: RAW el lanzamiento YA consumió la acción adicional del
    # turno 1 (casting_time bonus), así que el golpe repetido es del turno 2.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([]))

    # d20 14 (+6 = 20 vs CA 12) → impacto; 1d8 5 + mod 3 = 8.
    assert {:ok, msg, change} = Actions.spiritual_weapon_attack(w, "Cora", "Goblin", seq([14, 5]))

    assert msg =~ "arma espiritual"
    assert msg =~ "20 vs CA 12"
    assert msg =~ "8 de daño de fuerza"

    assert {:ok, w2} = change.(w)
    assert w2.characters["Goblin"].hp == 30 - 6 - 8
    assert w2.spell_slots["Cora"][2] == 2
    assert spent?() == []
  end

  test "crítico dobla los DADOS, no el mod; el fallo no daña" do
    w = world([cleric(), goblin()])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, "Goblin", seq([15, 6]))

    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([]))

    # Nat 20: (4+4) + 3 = 11.
    assert {:ok, msg, change} = Actions.spiritual_weapon_attack(w, "Cora", "Goblin", seq([20, 4]))
    assert msg =~ "CRÍTICO"
    assert msg =~ "11 de daño de fuerza"
    assert {:ok, w2} = change.(w)
    assert w2.characters["Goblin"].hp == 30 - 6 - 11

    {:ok, w3} = World.next_round().(w2)
    w3 = turn!(w3, "Cora", seq([]))

    # Fallo: 2 (+6 = 8 vs CA 12).
    assert {:ok, miss, _} = Actions.spiritual_weapon_attack(w3, "Cora", "Goblin", seq([2]))
    assert miss =~ "fallo"
    assert w3.characters["Goblin"].hp == 30 - 6 - 11
    assert spent?() == []
  end

  test "faerie fire concede ventaja al golpe del arma espiritual" do
    marked = %{
      goblin()
      | conditions: [%{"condition" => "faerie_fire", "source" => "faerie_fire:X"}]
    }

    w = world([cleric(), marked])
    w = turn!(w, "Cora")

    # El ataque inicial TAMBIÉN ve la ventaja de la marca: dos d20 (15, 3).
    {_msg, w} = cast!(w, "Goblin", seq([15, 3, 6]))

    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([]))

    # Ventaja: dos d20 (18, 3) → 18+6 = 24; daño 6+3 = 9.
    assert {:ok, msg, _} = Actions.spiritual_weapon_attack(w, "Cora", "Goblin", seq([18, 3, 6]))
    assert msg =~ "(ventaja)"
    assert msg =~ "9 de daño de fuerza"
    assert spent?() == []
  end

  test "sin postura, objetivo inexistente o muerto: error sin mutar ni tirar" do
    w = world([cleric(), goblin()])

    assert {:error, msg} = Actions.spiritual_weapon_attack(w, "Cora", "Goblin", &no_roll/1)
    assert msg =~ "no tiene un arma espiritual activa"

    w2 = turn!(w, "Cora")
    {_msg, w2} = cast!(w2, "Goblin", seq([15, 6]))

    # Turno nuevo: la acción adicional del turno 1 la consumió el lanzamiento.
    {:ok, w2} = World.next_round().(w2)
    w2 = turn!(w2, "Cora", seq([]))

    dead = %{goblin() | death_saves: %{successes: 0, fails: 3}}
    w2 = %{w2 | characters: Map.put(w2.characters, "Goblin", dead)}

    assert {:error, err} = Actions.spiritual_weapon_attack(w2, "Cora", "Goblin", &no_roll/1)
    assert err =~ "muerto"

    assert {:error, missing} = Actions.spiritual_weapon_attack(w2, "Cora", "Nadie", &no_roll/1)
    assert missing =~ "no existe el objetivo"
  end

  test "una sola acción adicional por turno (TurnBudget)" do
    w = world([cleric(), goblin()])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, "Goblin", seq([15, 6]))

    # Turno 2: el golpe de bonus está disponible de nuevo.
    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([]))

    assert {:ok, _msg, change} =
             Actions.spiritual_weapon_attack(w, "Cora", "Goblin", seq([14, 5]))

    assert {:ok, w2} = change.(w)

    assert {:error, budget} = Actions.spiritual_weapon_attack(w2, "Cora", "Goblin", seq([14, 5]))
    assert budget =~ "acción adicional"
    assert w2.characters["Goblin"].hp == 30 - 6 - 8
  end

  test "rounds_left decrementa SOLO en turno nuevo; a 0 la postura muere" do
    w = world([cleric(), goblin()])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, "Goblin", seq([15, 6]))
    assert posture(w)["rounds_left"] == 10

    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([]))
    assert posture(w)["rounds_left"] == 9

    # Re-selección y reacción en la misma ronda no envejecen.
    {:ok, same} = World.set_current_combatant("Cora", "main", &no_roll/1).(w)
    assert posture(same)["rounds_left"] == 9
    {:ok, reaction} = World.set_current_combatant("Cora", "reaction", &no_roll/1).(w)
    assert posture(reaction)["rounds_left"] == 9

    # 9 turnos nuevos más (10 en total) y la postura muere.
    w =
      Enum.reduce(1..9, w, fn _, acc ->
        {:ok, acc} = World.next_round().(acc)
        turn!(acc, "Cora", seq([]))
      end)

    assert posture(w) == nil
    assert w.log |> Enum.map(&elem(&1, 1)) |> Enum.join(" ") =~ "se desvanece"
  end

  test "relanzar SUSTITUYE la postura (no apila) y renueva rondas" do
    # L9: el relanzamiento sube a 4º (2d8) con casillas de 4º disponibles.
    w = world([cleric(level: 9), goblin()])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, "Goblin", seq([15, 6]))

    {:ok, w} = World.next_round().(w)
    w = turn!(w, "Cora", seq([]))
    assert posture(w)["rounds_left"] == 9

    {_msg, w} = cast!(w, "Goblin", seq([15, 3, 6, 2]), 4)

    entries =
      Enum.filter(
        w.characters["Cora"].conditions,
        &match?(%{"condition" => "spiritual_weapon"}, &1)
      )

    assert length(entries) == 1
    assert posture(w)["rounds_left"] == 10
    assert posture(w)["dice"] == "2d8"
    assert w.spell_slots["Cora"][4] == 2
  end

  test "Codec conserva la postura con dados, mod y rondas" do
    w = world([cleric(), goblin()])
    w = turn!(w, "Cora")
    {_msg, w} = cast!(w, "Goblin", seq([15, 6]))

    again = Codec.decode(Codec.encode(w))

    entry =
      Enum.find(
        again.characters["Cora"].conditions,
        &match?(%{"condition" => "spiritual_weapon"}, &1)
      )

    assert entry["dice"] == "1d8"
    assert entry["mod"] == 3
    assert entry["rounds_left"] == 10
  end
end
