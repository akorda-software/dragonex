defmodule Dragonex.ToolsLevelUpTest do
  @moduledoc """
  La tool `level_up` del DM solo sube a personajes que NO sean PCs humanos:
  un jugador real (incluso en auto-play) sube siempre desde su ficha. Para el
  resto (NPCs, enemigos, PCs de IA) aplica las `opts` (ASI, hechizos nuevos).
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Heroes, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  test "rechaza subir a un PC humano y se lo recuerda al DM" do
    ctx = %{deps: %{human_pcs: MapSet.new(["Thane"])}}

    assert {:ok, msg} = Tools.level_up(ctx, "Thane", %{})
    assert msg =~ "jugador humano"
    assert msg =~ "ficha"
  end

  test "sube a un PC de IA aplicando opts de ASI a nivel 4" do
    # Fighter nivel 3 → el siguiente nivel (4) concede ASI. Lo construimos sin
    # DB aplicando dos subidas al Character nivel 1 del builder.
    {:ok, c1} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, c2} = Heroes.LevelUp.apply(c1, %{})
    {:ok, c3} = Heroes.LevelUp.apply(c2, %{})
    str_before = c3.str

    game =
      start_session(
        world: World.new(characters: %{"Thane" => c3}),
        policy: :round_robin,
        participants: [p("dm")]
      )

    assert {:ok, "dm"} = Session.start(game)

    handle = SharedState.new(game, "dm")

    ctx = %{deps: %{state: handle, roller: fixed_roller(10), human_pcs: MapSet.new([])}}

    assert {:ok, msg} = Tools.level_up(ctx, "Thane", %{"asi" => %{"str" => 2}})
    assert msg =~ "sube de nivel"

    leveled = Session.read_state(game).characters["Thane"]
    assert leveled.level == 4
    assert leveled.str == min(20, str_before + 2)
  end

  test "opts vacías suben sin elecciones (solo PG + slots)" do
    {:ok, c1} =
      Heroes.build(%{name: "Lyra", race: "human", class: "fighter", background: "soldier"})

    game =
      start_session(
        world: World.new(characters: %{"Lyra" => c1}),
        policy: :round_robin,
        participants: [p("dm")]
      )

    assert {:ok, "dm"} = Session.start(game)

    ctx = %{
      deps: %{
        state: SharedState.new(game, "dm"),
        roller: fixed_roller(10),
        human_pcs: MapSet.new([])
      }
    }

    assert {:ok, _} = Tools.level_up(ctx, "Lyra", %{})

    leveled = Session.read_state(game).characters["Lyra"]
    assert leveled.level == 2
    assert leveled.max_hp > c1.max_hp
  end

  test "opts basura del LLM se normalizan a seguro sin romper" do
    # El LLM emite JSON no confiable: claves raras, ASI no entero / de ability
    # desconocida, hechizos inexistentes y 'spells' que no es lista. La tool
    # debe normalizar todo a una subida limpia (sin cambios espurios).
    {:ok, c1} =
      Heroes.build(%{name: "Vex", race: "human", class: "fighter", background: "soldier"})

    game =
      start_session(
        world: World.new(characters: %{"Vex" => c1}),
        policy: :round_robin,
        participants: [p("dm")]
      )

    assert {:ok, "dm"} = Session.start(game)

    ctx = %{
      deps: %{
        state: SharedState.new(game, "dm"),
        roller: fixed_roller(10),
        human_pcs: MapSet.new([])
      }
    }

    garbage = %{
      "asi" => %{"str" => "two", "foobar" => 5, "dex" => nil},
      "spells" => "definitely_not_a_spell",
      "unknown_key" => 42
    }

    assert {:ok, msg} = Tools.level_up(ctx, "Vex", garbage)
    assert msg =~ "sube de nivel"

    leveled = Session.read_state(game).characters["Vex"]
    assert leveled.level == 2
    # Sin cambios espurios: mismas características y sin hechizos nuevos.
    assert leveled.str == c1.str
    assert leveled.dex == c1.dex
    assert leveled.spells == c1.spells
  end
end
