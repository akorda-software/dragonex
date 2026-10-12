defmodule DragonexWeb.GameHistoryLiveTest do
  use DragonexWeb.ConnCase, async: false

  alias Dragonex.{Accounts, Archetypes, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "history-#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "Cronista"
      })

    {:ok, game} =
      Games.create_game(
        title: "Crónica larga",
        scene: "Una biblioteca",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    %{game: game, conn: conn}
  end

  test "loaded history survives new narration, pause updates and deletion of a retried segment",
       %{
         game: game,
         conn: conn
       } do
    for i <- 1..250, do: append(game.id, "Recuerdo #{i}")

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    refute "Recuerdo 1" in messages(view)
    view |> element(".load-more-btn") |> render_click()
    assert "Recuerdo 1" in messages(view)

    append(game.id, "Una nueva página")
    refresh(game.id)
    html = render(view)
    assert "Recuerdo 1" in messages(view)
    assert html =~ "Una nueva página"
    refute has_element?(view, ".load-more-btn")

    # Re-rendering must read the authoritative retained range. A merge of old
    # assigns would preserve a segment that Settlement removed during retry.
    {:ok, _} =
      Games.append_event(game.id, :narration, "dm", "all", %{
        text: "Fragmento truncado",
        turn_id: "retry-history"
      })

    refresh(game.id)
    assert render(view) =~ "Fragmento truncado"
    Games.delete_narrations_for_turn(game.id, "retry-history")
    refresh(game.id)
    refute render(view) =~ "Fragmento truncado"
    assert "Recuerdo 1" in messages(view)
  end

  test "paging regroups a turn whose marker and narration straddle the initial window", %{
    game: game,
    conn: conn
  } do
    for i <- 1..42 do
      {:ok, _} =
        Games.append_event(game.id, :turn, "Capítulo #{i}", "all", %{
          kind: "start",
          turn_id: "chapter-#{i}",
          round: i,
          phase: "exploration"
        })

      for line <- 1..5, do: append(game.id, "Episodio #{i}, línea #{line}")
    end

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element(".load-more-btn") |> render_click()

    # The original window starts in chapter 9. Its newly loaded marker must
    # contain ALL five lines in the same block, not leave a separate prologue.
    block = view |> element(".turn-block", "Turno de Capítulo 9") |> render()
    for line <- 1..5, do: assert(block =~ "Episodio 9, línea #{line}")
    assert Enum.count(nodes(view, ".turn-head")) == 42
    assert Enum.count(nodes(view, ".turn-block")) == 43
  end

  test "a page containing only DM secrets does not strand a player's older public history", %{
    game: game,
    conn: conn
  } do
    append(game.id, "La puerta pública")
    for i <- 1..210, do: append(game.id, "Clave privada #{i}", "dm")

    {:ok, view, html} = live(conn, "/games/#{game.id}")
    refute html =~ "La puerta pública"
    refute html =~ "Clave privada"
    view |> element(".load-more-btn") |> render_click()
    assert render(view) =~ "La puerta pública"
    refute render(view) =~ "Clave privada"
  end

  test "repeated paging stays bounded while keeping the latest events visible", %{
    game: game,
    conn: conn
  } do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for seq <- 3..2_302 do
        %{
          game_id: game.id,
          seq: seq,
          type: :narration,
          actor: "dm",
          visible_to: "all",
          payload: %{"text" => "Página #{seq}"},
          inserted_at: timestamp
        }
      end

    Dragonex.Repo.insert_all(Dragonex.Games.GameEvent, rows)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    for _ <- 1..24, do: render_click(view, "load_more_log")

    assert Enum.count(nodes(view, "#log [data-log-entry]")) == 2_000
    assert "Página 2302" in messages(view)
    refute "Página 3" in messages(view)
    refute has_element?(view, ".load-more-btn")
    assert has_element?(view, ".history-limit", "crónica completa sigue guardada")
    assert Games.count_events(game.id) == 2_302
  end

  defp append(game_id, text, visible_to \\ "all") do
    {:ok, _} = Games.append_event(game_id, :narration, "dm", visible_to, %{text: text})
  end

  defp refresh(game_id) do
    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{game_id}",
      {:game_updated, game_id}
    )
  end

  defp messages(view) do
    view |> nodes("#log .msg") |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
  end

  defp nodes(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end
end
