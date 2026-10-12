defmodule DragonexWeb.GameTableControlsTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Game, Games, World}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "controls-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Controles",
        scene: "Una sala",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{conn: conn, game: game}
  end

  test "the sheet is a named button with an expanded state retained across updates", %{
    conn: conn,
    game: game
  } do
    {:ok, view, _} = live(conn, "/games/#{game.id}")

    assert has_element?(
             view,
             "button#sheet-drawer[aria-expanded=false][aria-controls=player-sheets]",
             "Ficha"
           )

    view |> element("#sheet-drawer") |> render_click()
    assert has_element?(view, "button#sheet-drawer[aria-expanded=true]")
    assert has_element?(view, "#player-sheets.is-open", "Thane")

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{game.id}",
      {:game_updated, game.id}
    )

    assert has_element?(view, "button#sheet-drawer[aria-expanded=true]")
  end

  test "DM inspection offers a return to the player's seat instead of an unusable composer", %{
    conn: conn,
    game: game
  } do
    {:ok, view, _} = live(conn, "/games/#{game.id}?as=dm")
    refute has_element?(view, "#player-input")
    assert has_element?(view, ".dm-view-note a", "Volver a mi personaje")
  end

  test "a human declaration is readable in a native disclosure and survives a snapshot update", %{
    conn: conn,
    game: game
  } do
    declaration = "Busco huellas junto a la puerta y aviso al grupo."

    {:ok, event} =
      Games.append_event(game.id, :action, "Thane", "all", %{
        text: declaration,
        turn_id: "human-declaration"
      })

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    selector = "#event-#{event.seq} details.player-declaration"
    assert has_element?(view, "#{selector} > summary", "Thane declara")
    assert has_element?(view, "#{selector} .player-declaration-text", declaration)

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{game.id}",
      {:game_updated, game.id}
    )

    assert has_element?(view, "#{selector} .player-declaration-text", declaration)
  end

  test "a disclosed declaration escapes HTML and leaves narration as prose", %{
    conn: conn,
    game: game
  } do
    {:ok, _} =
      Games.append_event(game.id, :action, "Thane", "all", %{
        text: "Leo el aviso <script>alert('mapa')</script>."
      })

    {:ok, _} =
      Games.append_event(game.id, :narration, "dm", "all", %{text: "La puerta sigue cerrada."})

    {:ok, view, html} = live(conn, "/games/#{game.id}")
    assert has_element?(view, "details.player-declaration .player-declaration-text", "<script>")
    refute has_element?(view, "#log script")
    assert html =~ "&lt;script&gt;"
    assert has_element?(view, "#log .msg-dm", "La puerta sigue cerrada.")
    refute has_element?(view, "#log .msg-dm details")
  end

  test "a stopped game preserves a submitted draft and explains how to recover", %{
    conn: conn,
    game: game
  } do
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> form("#player-input", text: "Busco las huellas") |> render_change()
    :ok = Dragonex.Game.Supervisor.stop_game(game.id)
    view |> form("#player-input", text: "Busco las huellas") |> render_submit()

    assert has_element?(
             view,
             "#player-input-text[value='Busco las huellas'][aria-describedby=player-input-error]"
           )

    assert has_element?(view, "#player-input-error[role=alert]", "Recarga")
    assert Games.get_game(game.id).intents == %{}
  end

  test "an empty submission cannot erase an already queued intention", %{conn: conn, game: game} do
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    pid = Dragonex.Game.Supervisor.whereis(game.id)
    assert {:ok, :queued} = Game.declare(pid, "Thane", "Vigilo la puerta")
    render_submit(view, "declare", %{"text" => "   "})
    assert Game.snapshot(pid).intents == %{"Thane" => "Vigilo la puerta"}
    assert has_element?(view, "#player-input button[disabled]")
  end

  test "the streaming preview applies the DM's PC sanitization too", %{conn: conn, game: game} do
    {:ok, view, _} = live(conn, "/games/#{game.id}")

    send(
      view.pid,
      {:text_delta, game.id, "preview", "dm",
       "Borin dice: «¿Listos?» Thane asiente. El fuego crepita."}
    )

    html = view |> element(".live-streaming") |> render()
    assert html =~ "Borin dice"
    assert html =~ "El fuego crepita"
    refute html =~ "Thane asiente"
  end

  test "the table stream suppresses the real subordinate action using a compound PC's short name",
       %{conn: conn, game: game} do
    {:ok, sira_game} =
      Games.create_game(
        title: "La chispa",
        user_id: game.user_id,
        roster: [{Archetypes.wizard(name: "Sira de la Chispa"), :human}]
      )

    {:ok, _} =
      Games.save_state(sira_game.id, Games.load_world(sira_game), "Sira de la Chispa", 1, :paused)

    {:ok, view, _} = live(conn, "/games/#{sira_game.id}")
    raw = File.read!(Path.expand("../fixtures/narration/dm_sira_short_name.txt", __DIR__))
    send(view.pid, {:text_delta, sira_game.id, "short-preview", "dm", raw})

    html = view |> element(".live-streaming") |> render()
    assert html =~ "El cuarto se llena de un leve olor a ozono."
    assert html =~ "muchacho pálido del gremio de barqueros"
    refute html =~ "deja caer"
  end

  test "the table stream retains registered NPC voice with a PC-name prefix", %{
    conn: conn,
    game: game
  } do
    npc = %{Archetypes.wizard(name: "Thane del Muelle") | side: "npc"}
    {:ok, world} = World.add_character(npc).(Games.load_world(game))
    {:ok, _} = Games.save_state(game.id, world, "Thane", 1, :paused)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    raw = "«Volved al amanecer», dice Thane del Muelle. «Aceptamos», dice Thane."
    send(view.pid, {:text_delta, game.id, "npc-preview", "dm", raw})

    html = view |> element(".live-streaming") |> render()
    assert html =~ "Volved al amanecer"
    assert html =~ "dice Thane del Muelle"
    refute html =~ "Aceptamos"
  end

  test "only a successful declaration acknowledges the submitted draft", %{conn: conn, game: game} do
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> form("#player-input", text: "Vigilo la puerta") |> render_submit()
    game_id = game.id

    assert_push_event(view, "action_accepted", %{
      game_id: ^game_id,
      viewer: "Thane",
      text: "Vigilo la puerta"
    })

    assert has_element?(view, "#player-input-text[value='']")
  end

  test "a changed streaming actor starts a fresh bubble even with the same turn identifier", %{
    conn: conn,
    game: game
  } do
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    send(view.pid, {:text_delta, game.id, "shared-preview", "Lyra", "Busco el libro."})
    assert render(view) =~ "Busco el libro"
    send(view.pid, {:text_delta, game.id, "shared-preview", "Vex", "Vigilo la entrada."})
    html = view |> element(".live-streaming") |> render()
    assert html =~ "Vigilo la entrada"
    assert html =~ "Vex"
    refute html =~ "Busco el libro"
    refute html =~ "Lyra"
  end
end
