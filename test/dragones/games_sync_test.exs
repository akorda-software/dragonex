defmodule Dragones.GamesSyncTest do
  use ExUnit.Case, async: true

  alias Dragones.{Accounts, Games, Heroes}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)

    {:ok, user} =
      Accounts.register(%{email: "sync@test", password: "password123", display_name: "S"})

    {:ok, char} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, hero} = Accounts.save_hero(user, char)
    %{user: user, hero: hero, char: char}
  end

  test "games_using_hero y sync_hero_level_up propagan la subida a la partida", %{
    user: user,
    hero: hero
  } do
    sheet = Accounts.hero_sheet(hero)

    {:ok, game} =
      Games.create_game(
        title: "sync",
        scene: "una taberna",
        roster: [{sheet, :human, hero.id}]
      )

    assert game.id in Games.games_using_hero(hero.id)

    # El personaje en partida arranca en nivel 1 con algo de daño sufrido
    world = Games.load_world(game)
    {:ok, w2} = Dragones.World.apply_damage("Thane", 4).(world)
    {:ok, _} = Games.save_state(game.id, w2, nil, 1, :waiting)
    live = Games.load_world(Games.get_game(game.id)).characters["Thane"]
    assert live.level == 1
    assert live.hp == live.max_hp - 4

    # El jugador sube al héroe en su biblioteca (nivel 2, +2 STR vía ASI... no a L2; subida simple)
    {:ok, _leveled_hero} = Accounts.level_up_hero(user, hero.id, %{})
    new_sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))
    assert new_sheet.level == 2

    # Sincroniza la subida a la partida
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, new_sheet)

    reloaded = Games.load_world(Games.get_game(game.id))
    synced = reloaded.characters["Thane"]
    assert synced.level == 2
    # max_hp subió y el hp actual escaló conservando el daño sufrido (no curado a tope)
    assert synced.max_hp > live.max_hp
    assert synced.hp == synced.max_hp - 4
  end

  test "games_using_hero devuelve [] para un héroe sin partidas", %{hero: hero} do
    assert Games.games_using_hero(hero.id) == []
  end

  test "H2: merge_character_level_up propaga la AC recalculada (no se queda stale)" do
    alias Dragones.{Character, World}

    live =
      Character.new(
        name: "X",
        class: "fighter",
        level: 3,
        str: 16,
        dex: 12,
        con: 14,
        int: 10,
        wis: 10,
        cha: 10,
        hp: 28,
        max_hp: 28,
        ac: 11
      )

    world = World.new(characters: %{"X" => live})

    # new_sheet tras un ASI de DEX (sin armadura → AC 10+dex sube de 11 a 12)
    new_sheet = %{live | level: 4, dex: 14, ac: 12, max_hp: 34, hp: 34}

    merged = Games.merge_character_level_up(world, "X", new_sheet)
    out = merged.characters["X"]

    assert out.level == 4
    assert out.dex == 14
    assert out.ac == 12
  end
end
