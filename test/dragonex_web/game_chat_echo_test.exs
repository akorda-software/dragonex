defmodule DragonexWeb.GameChatEchoTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "echo-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Ecos",
        scene: "Un almacén",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{conn: conn, game: game}
  end

  defp append(game, type, actor, payload),
    do: Games.append_event(game.id, type, actor, "all", payload)

  defp occurrences(html, text), do: length(String.split(html, text)) - 1

  test "a voiced human action shows its words once, before its dice", %{conn: conn, game: game} do
    words = "Ataco al bandido con mi espada larga."
    turn = %{turn_id: "voz-thane"}

    {:ok, action} = append(game, :action, "Thane", Map.put(turn, :text, words))

    {:ok, dice} =
      append(game, :dice, "Thane", %{
        who: "Thane",
        kind: "attack",
        dice: [[20, 8]],
        total: 13,
        outcome: "hit",
        turn_id: "voz-thane"
      })

    {:ok, voice} =
      append(game, :narration, "Thane", %{
        text: words,
        turn_id: "voz-thane",
        kind: :human_declaration,
        complete: true
      })

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    log = view |> element("#log") |> render()

    assert occurrences(log, words) == 1
    assert has_element?(view, "#event-#{action.seq}.msg-pc", words)
    refute has_element?(view, "#event-#{action.seq} details.player-declaration")
    refute has_element?(view, "#event-#{voice.seq}")

    [{action_at, _}, {dice_at, _}] =
      for seq <- [action.seq, dice.seq], do: :binary.match(log, ~s(id="event-#{seq}"))

    assert action_at < dice_at
  end

  test "an intermediate copy of the DM's closure is shown once and survives updates", %{
    conn: conn,
    game: game
  } do
    text = "El bandido se dobla sobre la mesa y ya no se levanta; la campanilla rueda."

    {:ok, middle} =
      append(game, :narration, "dm", %{text: text, turn_id: "dm-1", complete: false})

    {:ok, closure} =
      append(game, :narration, "dm", %{text: text, turn_id: "dm-1", complete: true})

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert occurrences(view |> element("#log") |> render(), text) == 1
    assert has_element?(view, "#event-#{closure.seq}.msg-dm", text)
    refute has_element?(view, "#event-#{middle.seq}")

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{game.id}",
      {:game_updated, game.id}
    )

    assert occurrences(view |> element("#log") |> render(), text) == 1

    # The view folds the copy; the durable timeline keeps both events.
    seqs = for e <- Games.list_events(game.id), e.type == :narration, do: e.seq
    assert middle.seq in seqs and closure.seq in seqs
  end
end
