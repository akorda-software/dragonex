defmodule DragonexWeb.GameInventoryTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Archetypes, Game, Games, Item}
  alias DragonexWeb.GameLive.Components
  alias ExAgent.Models.Test

  test "own compact and detailed sheets display quantities and escaped labels" do
    card = %{
      Archetypes.wizard()
      | inventory: [
          %Item{name: "spellbook", qty: 1, kind: :gear},
          %Item{name: "botón de latón", qty: 2, kind: :gear},
          %Item{name: "<botón>", qty: 1, kind: :gear}
        ]
    }

    for component <- [&Components.sheet/1, &Components.detail_sheet/1] do
      html = render_component(component, card: card, mine: true)
      rows = html |> LazyHTML.from_fragment() |> LazyHTML.query(".inventory-list li")
      assert length(Enum.to_list(rows)) == 3
      assert LazyHTML.text(rows) =~ "Botón de latón"
      assert LazyHTML.text(rows) =~ "×2"
      refute html =~ "<botón>"
      assert html =~ "&lt;botón&gt;" or html =~ "&lt;Botón&gt;"
    end

    refute render_component(&Components.sheet/1, card: card) =~ "inventory-list"
  end

  test "confirmed Game inventory appears in both own sheets after the beat and reload, not in the reusable hero" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "inventory-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Mara"
      })

    card = %{Archetypes.wizard(name: "Mara") | inventory: []}
    {:ok, hero} = Accounts.save_hero(user, card)

    {:ok, game} =
      Games.create_game(
        title: "El botón guardado",
        scene: "El cruce del molino.",
        user_id: user.id,
        roster: [{card, :human, hero.id}]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), card.name, 1, :paused)

    model = %Test{
      script: [
        narration("Recojo el botón y pregunto al zagal."),
        tool_calls([
          call("grant_item", %{
            "who" => card.name,
            "item" => "botón de latón",
            "quantity" => 1,
            "source" => "Ada"
          })
        ]),
        narration("El zagal responde.")
      ]
    }

    recorder = %Test{
      script: [tool_calls([call("final_result", %{"scene" => game.world["scene"]})])]
    }

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, scene_model: recorder]}})

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    refute has_element?(view, ".inventory-list li", "Botón de latón")
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == card.name and &1.status == :waiting))

    assert {:ok, :resolving} =
             Game.declare(
               pid,
               card.name,
               "Le pregunto al zagal: ¿Es tuyo este botón? Lo recojo y guardo."
             )

    assert :ok = Game.await(pid, &(&1.current == card.name and &1.status == :waiting))
    assert :ok = Game.pause(pid)

    for own <- [".game-rail-left .card.mine", ".mobile-player-sheet"] do
      assert has_element?(view, own <> " .inventory-list li", "Botón de latón")
    end

    assert has_element?(
             view,
             "[data-event-kind=inventory_movement]",
             "Mara recibe 1 × botón de latón de Ada; saldo 0 → 1"
           )

    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, ".mobile-player-sheet .inventory-list li", "Botón de latón")

    assert [movement] =
             reloaded
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("[data-event-kind=inventory_movement]")
             |> Enum.to_list()

    assert LazyHTML.text(movement) =~ "de Ada; saldo 0 → 1"
    assert Accounts.hero_sheet(Accounts.get_hero(hero.id)).inventory == []
    assert [%Item{qty: 1}] = Game.world(pid).characters[card.name].inventory
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end
end
