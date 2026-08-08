defmodule Dragones.GameSyncGenserverTest do
  @moduledoc """
  Cubre el path del single-writer: `Game.sync_hero_level_up/3` (call) aplica el
  merge de la subida al `World` vivo del Session y persiste. Requiere sandbox
  `:shared` (async: false) porque el Game corre beats en Tasks.
  """

  use ExUnit.Case, async: false

  import Dragones.Test.Harness

  alias Dragones.{Accounts, Game, Games, Heroes, Monsters}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})

    {:ok, user} =
      Accounts.register(%{
        email: "sg#{System.unique_integer([:positive])}@test",
        password: "password123",
        display_name: "SG"
      })

    {:ok, char} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, hero} = Accounts.save_hero(user, char)

    {:ok, game} =
      Games.create_game(
        title: "sync-gs",
        scene: "una encrucijada",
        user_id: user.id,
        roster: [{Accounts.hero_sheet(hero), :human, hero.id}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    {:ok, user: user, hero: hero, game: game}
  end

  # DM (goblin) solo narra y cede el turno a Thane (humano, :waiting).
  defp script, do: [text("El goblin mira a Thane con recelo.")]
  defp roller, do: fn _n -> 1 end
  defp waiting_on(name), do: fn s -> s.status == :waiting and s.current == name end

  test "Game.sync_hero_level_up aplica el merge al world vivo (single-writer)", %{
    user: user,
    hero: hero,
    game: game
  } do
    pid =
      start_supervised!(
        {Dragones.Game, {game.id, [model: %Test{script: script()}, roller: roller()]}}
      )

    # Espera al turno humano (Thane) y pausa para evitar beats en vuelo.
    assert :ok = Game.await(pid, waiting_on("Thane"))
    assert :ok = Game.pause(pid)

    # El jugador sube a su héroe en la biblioteca (fuente de verdad).
    {:ok, _} = Accounts.level_up_hero(user, hero.id, %{})
    new_sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))
    assert new_sheet.level == 2

    # El GenServer aplica el merge al World vivo y persiste (single-writer).
    assert :ok = Game.sync_hero_level_up(pid, hero.id, new_sheet)

    assert Game.world(pid).characters["Thane"].level == 2

    # Y persistió: recargando desde DB el nivel también es 2.
    reloaded = Games.load_world(Games.get_game(game.id))
    assert reloaded.characters["Thane"].level == 2
  end
end
