defmodule Dragonex.GameWildShapeProgressionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Actions, Archetypes, Character, Game, Games, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp druid do
    Character.new(
      name: "Sylvi",
      race: "human",
      class: "druid",
      level: 2,
      str: 10,
      dex: 14,
      con: 18,
      int: 12,
      wis: 16,
      cha: 10,
      hp: 7,
      max_hp: 20,
      ac: 12,
      wild_shape_uses: 2
    )
  end

  # Seed only a stopped game; every subsequent change uses its Game writer.
  defp seed(game, current) do
    w = Games.load_world(game)
    {:ok, _, change} = Actions.wild_shape(w, "Sylvi", "wolf")
    {:ok, w} = change.(w)
    {:ok, w} = World.apply_damage("Sylvi", 5).(w)
    {:ok, w} = World.consume_slot("Sylvi", 1).(w)
    w = %{w | elapsed_seconds: 99, rest_state: %{"Sylvi" => %{"hit_dice_used" => 1}}}
    {:ok, _} = Games.save_state(game.id, w, current, w.round, :paused)
    w
  end

  test "owned library sync keeps the beast across pause and reopen, then the human reverts to the progressed form" do
    {:ok, user} =
      Accounts.register(%{
        email: "shape-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Druida"
      })

    {:ok, hero} = Accounts.save_hero(user, druid())

    {:ok, game} =
      Games.create_game(
        title: "Dos formas",
        user_id: user.id,
        roster: [{druid(), :human, hero.id}]
      )

    before = seed(game, "Sylvi")

    model = %Test{
      script: [
        tool_calls([call("end_wild_shape", %{"who" => "Sylvi"})]),
        narration("Vuelvo a mi forma original."),
        narration("La sala guarda silencio. ¿Qué haces?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert {:ok, progressed} = Accounts.level_up_hero(user, hero.id, %{expected_level: 2})
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, Accounts.hero_sheet(progressed))
    active = Game.world(pid)
    assert active.characters["Sylvi"].level == 3
    assert active.characters["Sylvi"].hp == 6 and active.characters["Sylvi"].max_hp == 11
    assert active.characters["Sylvi"].con == 12
    assert active.characters["Sylvi"].wild_shape.orig_max_hp == 29
    assert active.characters["Sylvi"].wild_shape.orig_hp == 7
    assert active.spell_slots["Sylvi"] == %{1 => 3, 2 => 2}

    assert active.rest_state == before.rest_state and
             active.elapsed_seconds == before.elapsed_seconds

    assert Game.snapshot(pid).status == :paused
    assert Games.load_world(Games.get_game(game.id)) == active
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, Accounts.hero_sheet(progressed))
    assert Game.world(pid) == active
    assert :ok = stop_supervised({Game, game.id})

    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert Game.world(reopened) == active
    assert :ok = Game.resume(reopened)
    assert :ok = Game.await(reopened, &(&1.current == "Sylvi" and &1.status == :waiting))
    assert {:ok, :resolving} = Game.declare(reopened, "Sylvi", "Vuelvo a mi forma original.")
    assert :ok = Game.await(reopened, &(&1.current == "Sylvi" and &1.status == :waiting))
    assert :ok = Game.pause(reopened)
    native = Game.world(reopened)
    assert native.characters["Sylvi"].wild_shape == nil
    assert native.characters["Sylvi"].hp == 7 and native.characters["Sylvi"].max_hp == 29
    assert native.characters["Sylvi"].con == 18 and native.characters["Sylvi"].dex == 14
    assert native.characters["Sylvi"].wild_shape_uses == 1

    assert native.rest_state == before.rest_state and
             native.elapsed_seconds == before.elapsed_seconds

    assert Games.load_world(Games.get_game(game.id)) == native
  end

  test "a TestModel DM level-up preserves its AI druid's beast and progresses the stored original" do
    {:ok, game} =
      Games.create_game(
        title: "Subida del druida",
        roster: [{Archetypes.fighter(), :human}, {druid(), :ai}]
      )

    before = seed(game, "dm")

    model = %Test{
      script: [
        tool_calls([call("level_up", %{"target" => "Sylvi", "opts" => %{}})]),
        narration("Thane, ¿qué quieres hacer?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    active = Game.world(pid)
    assert active.characters["Sylvi"].level == 3
    assert active.characters["Sylvi"].hp == 6 and active.characters["Sylvi"].max_hp == 11
    assert active.characters["Sylvi"].con == 12
    assert active.characters["Sylvi"].wild_shape.orig_max_hp == 29
    assert active.characters["Sylvi"].wild_shape.orig_hp == 7
    assert active.characters["Sylvi"].wild_shape_uses == 1
    assert active.spell_slots["Sylvi"] == %{1 => 3, 2 => 2}

    assert active.rest_state == before.rest_state and
             active.elapsed_seconds == before.elapsed_seconds

    assert Games.load_world(Games.get_game(game.id)) == active
  end
end
