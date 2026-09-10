defmodule Dragonex.GrantXpTest do
  @moduledoc """
  Tool `grant_xp` (D43): DM grants XP in-game. Does not level up.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Character, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp ctx_for(game) do
    %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(10)}}
  end

  test "mensaje factual incluye total, umbral y can_level_up?" do
    hero = Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12, side: "pc")

    game =
      start_session(
        world: World.new(characters: %{"Thane" => hero}),
        policy: :round_robin,
        participants: [p("dm")]
      )

    assert {:ok, "dm"} = Session.start(game)

    assert {:ok, msg} = Tools.grant_xp(ctx_for(game), "Thane", 300)
    assert msg =~ "300 XP"
    assert msg =~ "total 300"
    assert msg =~ "umbral siguiente nivel 300"
    assert msg =~ "puede subir de nivel"

    c = Session.read_state(game).characters["Thane"]
    assert c.xp == 300
    assert c.level == 1
  end

  test "+100 no llega al umbral" do
    hero = Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12, side: "pc")

    game =
      start_session(
        world: World.new(characters: %{"Thane" => hero}),
        policy: :round_robin,
        participants: [p("dm")]
      )

    assert {:ok, "dm"} = Session.start(game)

    assert {:ok, msg} = Tools.grant_xp(ctx_for(game), "Thane", 100)
    assert msg =~ "total 100"
    assert msg =~ "umbral siguiente nivel 300"
    assert msg =~ "aún no puede subir de nivel"
    refute Session.read_state(game).characters["Thane"].level == 2
  end

  test "PC no puede otorgar XP" do
    hero = Character.new(name: "Thane", class: "fighter", hp: 12, max_hp: 12, side: "pc")

    game =
      start_session(
        world: World.new(characters: %{"Thane" => hero}),
        policy: :round_robin,
        participants: [p("dm"), p("Thane")]
      )

    assert {:ok, "dm"} = Session.start(game)

    ctx = %{deps: %{state: SharedState.new(game, "Thane"), roller: fixed_roller(10)}}
    assert {:error, msg} = Tools.grant_xp(ctx, "Thane", 300)
    assert msg =~ "RECHAZADO"
    assert Session.read_state(game).characters["Thane"].xp == 0
  end
end
