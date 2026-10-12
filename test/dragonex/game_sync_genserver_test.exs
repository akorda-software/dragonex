defmodule Dragonex.GameSyncGenserverTest do
  @moduledoc """
  Cubre el path del single-writer: `Game.sync_hero_level_up/3` (call) aplica el
  merge de la subida al `World` vivo del Session y persiste. Requiere sandbox
  `:shared` (async: false) porque el Game corre beats en Tasks.
  """

  use ExUnit.Case, async: false

  import Dragonex.Test.Harness

  alias Dragonex.{Accounts, Actions, Archetypes, Game, Games, Heroes, Monsters, Rest, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()

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
  defp script, do: [narration("El goblin mira a Thane con recelo.")]
  defp roller, do: fn _n -> 1 end
  defp waiting_on(name), do: fn s -> s.status == :waiting and s.current == name end

  # Prepara el world persistido con daño + una condición antes de arrancar el
  # GenServer (que rehidrata desde DB), para verificar que la sync los conserva.
  defp wound_thane_in_db(game) do
    world = Games.load_world(Games.get_game(game.id))
    {:ok, w1} = Dragonex.World.apply_damage("Thane", 5).(world)
    {:ok, w2} = Dragonex.World.apply_condition("Thane", "frightened").(w1)
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
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: script()}, roller: roller()]}}
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
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, new_sheet)

    synced = Game.world(pid).characters["Thane"]
    assert synced.level == 2

    # RAW 5e: subir de nivel NO cura. El daño sufrido (5) se conserva; solo
    # subió el máximo. La condición también sobrevive al merge (no la pisa).
    assert synced.hp == hp_before
    assert synced.max_hp > max_before
    assert Dragonex.World.has_condition?(Game.world(pid), "Thane", "frightened")

    # Y persistió: recargando desde DB el nivel es 2 y el daño se conserva.
    reloaded = Games.load_world(Games.get_game(game.id))
    assert reloaded.characters["Thane"].level == 2
    assert reloaded.characters["Thane"].hp == hp_before
  end

  test "sync of a paused game without a process rehydrates its sole writer and keeps expenditure",
       %{
         user: user
       } do
    sheet = Archetypes.wizard()
    {:ok, hero} = Accounts.save_hero(user, sheet)

    {:ok, game} =
      Games.create_game(
        title: "Dormant progression",
        user_id: user.id,
        roster: [{sheet, :human, hero.id}]
      )

    before = Games.load_world(game)
    {:ok, before} = World.consume_slot(sheet.name, 1).(before)
    {:ok, before} = World.apply_damage(sheet.name, 3).(before)
    {:ok, _} = Games.save_state(game.id, before, sheet.name, before.round, :paused)
    assert is_nil(Game.Supervisor.whereis(game.id))
    assert {:ok, leveled} = Accounts.level_up_hero(user, hero.id, %{expected_level: 1})
    events_before = Games.list_events(game.id)

    try do
      assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, Accounts.hero_sheet(leveled))
      pid = Game.Supervisor.whereis(game.id)
      assert is_pid(pid)
      after_world = Game.world(pid)
      assert after_world.characters[sheet.name].level == 2
      assert after_world.spell_slots[sheet.name] == %{1 => 2}
      assert after_world.characters[sheet.name].hp == before.characters[sheet.name].hp
      assert after_world.scene == before.scene
      assert after_world.elapsed_seconds == before.elapsed_seconds
      assert Game.snapshot(pid).status == :paused
      assert Game.current(pid) == sheet.name
      assert Games.load_world(Games.get_game(game.id)) == after_world
      assert Games.list_events(game.id) == events_before
    after
      Game.Supervisor.stop_game(game.id)
    end
  end

  test "caster sync and reopening preserve spent slots, hit dice and the long-rest deadline", %{
    user: user
  } do
    sheet = Archetypes.wizard()
    {:ok, hero} = Accounts.save_hero(user, sheet)

    {:ok, game} =
      Games.create_game(
        title: "Caster progression",
        user_id: user.id,
        roster: [{sheet, :human, hero.id}]
      )

    before = Games.load_world(game)
    {:ok, before} = World.consume_slot(sheet.name, 1).(before)
    {:ok, before} = World.apply_damage(sheet.name, 3).(before)

    before = %{
      before
      | rest_state: %{sheet.name => %{"hit_dice_used" => 1, "last_long_rest_start" => 0}},
        elapsed_seconds: 100
    }

    {:ok, _} = Games.save_state(game.id, before, sheet.name, before.round, :paused)

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(pid).spell_slots[sheet.name] == %{1 => 1}
    assert {:ok, leveled_hero} = Accounts.level_up_hero(user, hero.id)
    new_sheet = Accounts.hero_sheet(leveled_hero)
    assert :ok = Game.sync_hero_level_up(pid, hero.id, new_sheet)
    after_world = Game.world(pid)
    assert after_world.spell_slots[sheet.name] == %{1 => 2}
    assert after_world.characters[sheet.name].hp == before.characters[sheet.name].hp
    assert after_world.characters[sheet.name].max_hp > sheet.max_hp
    assert after_world.rest_state == before.rest_state
    assert after_world.elapsed_seconds == before.elapsed_seconds
    assert Rest.remaining(after_world, sheet.name) == 1
    assert {:error, _} = Rest.validate(after_world, sheet.name, :long)
    assert :ok = Game.sync_hero_level_up(pid, hero.id, new_sheet)
    assert Game.world(pid) == after_world
    assert Games.load_world(Games.get_game(game.id)) == after_world
    assert :ok = stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == after_world
    assert Game.snapshot(reopened).status == :paused
    assert {:error, :stale_level} = Game.sync_hero_level_up(reopened, hero.id, sheet)
    assert Game.world(reopened) == after_world
    assert Games.load_world(Games.get_game(game.id)) == after_world
    gc = Enum.find(Games.get_game(game.id).characters, &(&1.hero_id == hero.id))
    assert Dragonex.Codec.decode_character(gc.sheet).level == 2
  end

  test "a TestModel DM level-up adds capacity without resting the AI caster", %{user: user} do
    {:ok, game} =
      Games.create_game(
        title: "DM progression",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, before} = World.consume_slot("Lyra", 1).(before)
    {:ok, before} = World.consume_slot("Lyra", 1).(before)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)

    model = %Test{
      script: [
        tool_calls([call("level_up", %{"target" => "Lyra", "opts" => %{}})]),
        narration("Thane, ¿qué quieres comprobar antes de salir?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.resume(pid)
    assert :ok = Game.await_turn(pid, "Thane")
    assert :ok = Game.pause(pid)
    after_world = Game.world(pid)
    assert after_world.characters["Lyra"].level == 2
    assert after_world.spell_slots["Lyra"] == %{1 => 1}
    assert after_world.characters["Lyra"].hp == before.characters["Lyra"].hp
    assert after_world.elapsed_seconds == before.elapsed_seconds
    assert Games.load_world(Games.get_game(game.id)) == after_world
  end

  test "library progression preserves the live sorcery payment and adds only one point", %{
    user: user
  } do
    {:ok, sheet} =
      Heroes.build(%{
        name: "Sylas",
        race: "human",
        class: "sorcerer",
        background: "sage",
        level: 2
      })

    {:ok, hero} = Accounts.save_hero(user, sheet)

    {:ok, game} =
      Games.create_game(
        title: "Class resource sync",
        user_id: user.id,
        roster: [{sheet, :human, hero.id}]
      )

    before = Games.load_world(game)
    {:ok, _, change} = Actions.create_spell_slot(before, sheet.name, 1)
    {:ok, before} = change.(before)
    {:ok, _} = Games.save_state(game.id, before, sheet.name, before.round, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert {:ok, hero} = Accounts.level_up_hero(user, hero.id, %{expected_level: 2})
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, Accounts.hero_sheet(hero))
    after_world = Game.world(pid)
    assert after_world.characters[sheet.name].sorcery_points == 1
    assert after_world.spell_slots[sheet.name] == %{1 => 5, 2 => 2}
    assert after_world.characters[sheet.name].hp == before.characters[sheet.name].hp
    assert after_world.elapsed_seconds == before.elapsed_seconds
    assert :ok = Game.sync_hero_level_up(pid, hero.id, Accounts.hero_sheet(hero))
    assert Game.world(pid) == after_world
    assert Games.load_world(Games.get_game(game.id)) == after_world
    assert :ok = stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == after_world
    assert Game.snapshot(reopened).status == :paused
  end

  test "a TestModel DM unlocks the AI monk pool through the deterministic level-up tool", %{
    user: user
  } do
    {:ok, monk} = Heroes.build(%{name: "Shen", race: "human", class: "monk", background: "sage"})

    {:ok, game} =
      Games.create_game(
        title: "DM unlocks ki",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}, {monk, :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)

    model = %Test{
      script: [
        tool_calls([call("level_up", %{"target" => monk.name, "opts" => %{}})]),
        narration("Thane, ¿quieres seguir entrenando?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.resume(pid)
    assert :ok = Game.await_turn(pid, "Thane")
    assert :ok = Game.pause(pid)
    after_world = Game.world(pid)
    assert after_world.characters[monk.name].level == 2
    assert after_world.characters[monk.name].ki == 2
    assert after_world.characters[monk.name].hp == before.characters[monk.name].hp
    assert after_world.elapsed_seconds == before.elapsed_seconds
    assert Games.load_world(Games.get_game(game.id)) == after_world
  end
end
