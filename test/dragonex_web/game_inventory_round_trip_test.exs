defmodule DragonexWeb.GameInventoryRoundTripTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  test "a returned loan shows both movements after reload even with the original final balance" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "round-trip-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Mara"
      })

    card = %{Archetypes.wizard(name: "Mara") | inventory: []}
    {:ok, hero} = Accounts.save_hero(user, card)

    {:ok, game} =
      Games.create_game(
        title: "Préstamo devuelto",
        scene: "El puesto de Ada.",
        user_id: user.id,
        roster: [{card, :human, hero.id}]
      )

    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, game} = Games.save_state(game.id, before, card.name, 1, :paused)

    model = %Test{
      script: [
        narration("Le pido el sello a Ada para mirarlo y devolvérselo."),
        tool_calls([
          call("record_item_round_trip", %{
            "who" => card.name,
            "item" => "sello de latón",
            "quantity" => 1,
            "counterparty" => "[DM]: Ada",
            "direction" => "borrow_return"
          })
        ]),
        narration("Ada te presta el sello y lo recoge después de que lo examines.")
      ]
    }

    recorder = %Test{script: [tool_calls([call("final_result", %{"scene" => before.scene})])]}

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, scene_model: recorder]}})

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == card.name and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(
               pid,
               card.name,
               "Le pido prestado el sello a Ada, lo examino y se lo devuelvo inmediatamente."
             )

    assert :ok = Game.await(pid, &(&1.current == card.name and &1.status == :waiting))
    assert :ok = Game.pause(pid)

    assert has_element?(
             view,
             "[data-event-kind=inventory_movement]",
             "Mara recibe 1 × sello de latón de Ada; saldo 0 → 1"
           )

    assert has_element?(
             view,
             "[data-event-kind=inventory_movement]",
             "Mara entrega 1 × sello de latón a Ada; saldo 1 → 0"
           )

    refute has_element?(view, ".inventory-list li", "Sello de latón")

    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")

    assert [received, returned] =
             reloaded
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("[data-event-kind=inventory_movement]")
             |> Enum.to_list()

    assert LazyHTML.text(received) =~ "de Ada; saldo 0 → 1"
    assert LazyHTML.text(returned) =~ "a Ada; saldo 1 → 0"
    refute LazyHTML.text(received) =~ "[DM]"
    refute has_element?(reloaded, ".inventory-list li", "Sello de latón")
    assert Game.world(pid).characters[card.name].inventory == []
    assert Accounts.hero_sheet(Accounts.get_hero(hero.id)).inventory == []
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)

    assert [first, second] =
             Games.list_events(game.id)
             |> Enum.filter(&(&1.payload["kind"] == "inventory_movement"))

    assert first.payload["movement_group"] == second.payload["movement_group"]
    assert is_binary(first.payload["movement_group"])
    assert {first.payload["leg_index"], second.payload["leg_index"]} == {1, 2}
    assert first.payload["turn_id"] == second.payload["turn_id"]
  end
end
