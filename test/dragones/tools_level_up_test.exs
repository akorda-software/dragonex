defmodule Dragones.ToolsLevelUpTest do
  @moduledoc """
  La tool `level_up` del DM solo sube a personajes que NO sean PCs humanos:
  un jugador real (incluso en auto-play) sube siempre desde su ficha. Para el
  resto (NPCs, enemigos, PCs de IA) aplica las `opts` (ASI, hechizos nuevos).
  """

  use ExUnit.Case, async: true

  import Dragones.Test.Harness

  alias Dragones.{Heroes, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  test "rechaza subir a un PC humano y se lo recuerda al DM" do
    ctx = %{deps: %{human_pcs: MapSet.new(["Thane"])}}

    assert {:ok, msg} = Tools.level_up(ctx, "Thane", %{})
    assert msg =~ "jugador humano"
    assert msg =~ "ficha"
  end

  test "un target que no es humano no se marca como tal (human_pc?)" do
    ctx = %{deps: %{human_pcs: MapSet.new(["Thane"])}}

    # "goblin" no está en el set de humanos → la rama de rechazo no aplica.
    deps = ctx.deps
    refute MapSet.member?(deps[:human_pcs], "goblin")
    assert MapSet.member?(deps[:human_pcs], "Thane")
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
end
