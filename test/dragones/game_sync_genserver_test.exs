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

  # Prepara el world persistido con daño + una condición antes de arrancar el
  # GenServer (que rehidrata desde DB), para verificar que la sync los conserva.
  defp wound_thane_in_db(game) do
    world = Games.load_world(Games.get_game(game.id))
    {:ok, w1} = Dragones.World.apply_damage("Thane", 5).(world)
    {:ok, w2} = Dragones.World.apply_condition("Thane", "frightened").(w1)
    {:ok, _} = Games.save_state(game.id, w2, nil, 1, :waiting)
  end

  test "Game.sync_hero_level_up conserva hp dañado y condiciones (single-writer)", %{
    user: user,
    hero: hero,
    game: game
  } do
    # Thane llega dañado (5) y asustado al world antes de arrancar el GenServer.
    wound_thane_in_db(game)

    pid =
      start_supervised!(
        {Dragones.Game, {game.id, [model: %Test{script: script()}, roller: roller()]}}
      )

    # El world vivo rehidratado lleva el daño y la condición.
    world_before = Game.world(pid)
    max_before = world_before.characters["Thane"].max_hp
    hp_before = max_before - 5
    assert world_before.characters["Thane"].hp == hp_before

    assert :ok = Game.await(pid, waiting_on("Thane"))
    assert :ok = Game.pause(pid)

    # El jugador sube a su héroe en la biblioteca (fuente de verdad).
    {:ok, _} = Accounts.level_up_hero(user, hero.id, %{})
    new_sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))
    assert new_sheet.level == 2

    # El GenServer aplica el merge al World vivo y persiste (single-writer).
    assert :ok = Game.sync_hero_level_up(pid, hero.id, new_sheet)

    synced = Game.world(pid).characters["Thane"]
    assert synced.level == 2

    # RAW 5e: subir de nivel NO cura. El daño sufrido (5) se conserva; solo
    # subió el máximo. La condición también sobrevive al merge (no la pisa).
    assert synced.hp == hp_before
    assert synced.max_hp > max_before
    assert Dragones.World.has_condition?(Game.world(pid), "Thane", "frightened")

    # Y persistió: recargando desde DB el nivel es 2 y el daño se conserva.
    reloaded = Games.load_world(Games.get_game(game.id))
    assert reloaded.characters["Thane"].level == 2
    assert reloaded.characters["Thane"].hp == hp_before
  end
end
