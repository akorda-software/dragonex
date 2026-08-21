defmodule Dragonex.GamesSyncTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Accounts, Games, Heroes}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)

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
    {:ok, w2} = Dragonex.World.apply_damage("Thane", 4).(world)
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
    # RAW 5e: subir de nivel NO cura. max_hp sube pero el hp actual se conserva
    # exactamente (sin ASI de CON); el daño sufrido persiste.
    assert synced.max_hp > live.max_hp
    assert synced.hp == live.hp
  end

  test "games_using_hero devuelve [] para un héroe sin partidas", %{hero: hero} do
    assert Games.games_using_hero(hero.id) == []
  end

  test "H2: merge_character_level_up propaga la AC recalculada (no se queda stale)" do
    alias Dragonex.{Character, World}

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

  test "merge preserva el estado transitorio (temp_hp, death_saves, conditions, slots)" do
    alias Dragonex.{Character, World}

    live =
      Character.new(
        name: "X",
        class: "wizard",
        level: 1,
        str: 8,
        dex: 14,
        con: 14,
        int: 16,
        wis: 12,
        cha: 10,
        hp: 4,
        max_hp: 8,
        ac: 10,
        temp_hp: 5,
        death_saves: %{fails: 1, successes: 2},
        conditions: [%{condition: "poisoned"}, %{condition: "prone"}]
      )

    world = World.new(characters: %{"X" => live})
    world = World.init_spell_slots(world)
    # consume un slot de nivel 1
    {:ok, world} = World.consume_slot("X", 1).(world)
    assert world.spell_slots["X"][1] == 1

    new_sheet = %{live | level: 2, max_hp: 14, hp: 14}

    merged = Games.merge_character_level_up(world, "X", new_sheet)
    out = merged.characters["X"]

    # Los deltas del nivel se aplican
    assert out.level == 2
    assert out.max_hp == 14
    # RAW: hp no cura; conserva el daño sufrido (4)
    assert out.hp == 4

    # Estado transitorio preservado (no pisado por el merge)
    assert out.temp_hp == 5
    assert out.death_saves == %{fails: 1, successes: 2}
    assert out.conditions == [%{condition: "poisoned"}, %{condition: "prone"}]

    # Los slots del nuevo nivel se refrescan, pero el consumo previo NO se
    # "deshace": los slots máximos a L2 son 3×1; aquí simplemente se reponen.
    assert merged.spell_slots["X"][1] == 3
  end

  test "merge LOW-5: un caído (0 hp) sigue caído tras la sync" do
    alias Dragonex.{Character, World}

    live =
      Character.new(
        name: "Down",
        class: "fighter",
        level: 1,
        str: 16,
        dex: 12,
        con: 14,
        int: 10,
        wis: 10,
        cha: 10,
        hp: 0,
        max_hp: 12,
        ac: 16
      )

    world = World.new(characters: %{"Down" => live})
    new_sheet = %{live | level: 2, max_hp: 20, hp: 20}

    merged = Games.merge_character_level_up(world, "Down", new_sheet)
    out = merged.characters["Down"]

    assert out.level == 2
    assert out.max_hp == 20
    # RAW: subir de nivel no revive. Sigue a 0 hp.
    assert out.hp == 0
  end

  test "merge LOW-5: la vitalidad retroactiva de CON sube el hp actual" do
    alias Dragonex.{Character, World}

    live =
      Character.new(
        name: "Hurt",
        class: "fighter",
        level: 3,
        str: 16,
        dex: 12,
        con: 14,
        int: 10,
        wis: 10,
        cha: 10,
        hp: 10,
        max_hp: 28,
        ac: 16
      )

    world = World.new(characters: %{"Hurt" => live})
    # Subida con ASI de CON (14→16). con_retro = (3-2)*3 = 3
    new_sheet = %{live | level: 4, con: 16, max_hp: 40, hp: 40}

    merged = Games.merge_character_level_up(world, "Hurt", new_sheet)
    out = merged.characters["Hurt"]

    assert out.con == 16
    assert out.max_hp == 40
    # Solo la vitalidad de CON (+3), no el hp_gain del nuevo nivel.
    assert out.hp == 13
  end
end
