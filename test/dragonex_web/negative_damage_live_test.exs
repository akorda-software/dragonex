defmodule DragonexWeb.NegativeDamageLiveTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Archetypes, Character, Game, Games, Weapon, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "damage#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "Prueba de daño"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn, user: user}
  end

  test "a PC tool's zero damage breakdown survives Postgres and reloading the LiveView", %{
    conn: conn,
    user: user
  } do
    paladin =
      Character.new(
        name: "Arden",
        class: "paladin",
        level: 2,
        str: 6,
        dex: 6,
        hp: 16,
        max_hp: 16,
        weapons: [
          %Weapon{name: "club", dice: "1d4", attack_ability: :str, damage_type: "bludgeoning"}
        ]
      )

    enemy = Character.new(name: "Goblin", side: "enemy", hp: 10, max_hp: 10, ac: 10)

    {:ok, game} =
      Games.create_game(
        title: "Un mínimo de daño explicado",
        user_id: user.id,
        roster: [{paladin, :ai}, {Archetypes.fighter(), :human}, {enemy, :ai}],
        initiative: ["Arden", "Thane", "Goblin"]
      )

    before = Games.load_world(game)
    {:ok, before} = World.set_current_combatant("Arden").(before)
    {:ok, _} = Games.save_state(game.id, before, "Arden", before.round, :paused)
    values = start_supervised!({Agent, fn -> [15, 1, 2, 2] end})

    roller = fn sides ->
      value = Agent.get_and_update(values, fn [value | rest] -> {value, rest} end)
      assert value in 1..sides
      value
    end

    model = %Test{
      script: [
        tool_calls([call("divine_smite", %{"who" => "Arden", "slot_level" => 1})]),
        tool_calls([
          call("make_attack", %{
            "attacker" => "Arden",
            "target" => "Goblin",
            "weapon" => "club",
            "mode" => "normal"
          })
        ]),
        narration("Mi arma no hiere, pero la luz alcanza al enemigo.")
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model, roller: roller)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button", "Reanudar") |> render_click()
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    html = render(view)
    assert html =~ "d4:1 -2 = 0 (mínimo 0)"
    refute html =~ "d4:1 -1 = 0"

    event =
      Enum.find(Games.list_events(game.id), &(&1.type == :dice and &1.payload["raw_total"] == -1))

    assert event.payload["total"] == 0
    assert Game.world(pid).characters["Goblin"].hp == 6
    assert Game.world(pid).spell_slots["Arden"][1] == 1
    assert :ok == Game.pause(pid)
    {:ok, reopened, _} = live(conn, "/games/#{game.id}")
    assert render(reopened) =~ "d4:1 -2 = 0 (mínimo 0)"
    assert Agent.get(values, & &1) == []
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end
end
