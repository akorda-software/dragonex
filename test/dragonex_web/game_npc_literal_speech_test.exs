defmodule DragonexWeb.GameNPCLiteralSpeechTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]
  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  @question "Le pregunto a la tabernera: «¿Qué plato sirves hoy y cuánto cuesta?» Espero aquí su respuesta."
  @speech "—¿Qué plato sirves hoy y cuánto cuesta?"
  @answer "Maribel señala el caldero. —Tres monedas el plato."

  test "the player's exact question appears while only the NPC model is waiting, and survives reload" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "literal-npc-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Una pregunta propia"
      })

    {:ok, game} =
      Games.create_game(
        title: "El menú sin paráfrasis",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:literal_npc_ready, self(), inspect(messages, limit: :infinity)})
          receive do: (:finish -> narration(@answer))
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model)
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    view |> element("#player-input") |> render_submit(%{"text" => @question})
    assert_receive {:literal_npc_ready, run, context}, 2_000

    try do
      assert context =~ "Responde como ese PNJ"
      assert context =~ @speech
      assert Game.current(pid) == "dm"
      assert has_element?(view, "#log .msg-pc", @speech)
      refute has_element?(view, ".my-turn-banner")
    after
      send(run, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert has_element?(view, ".my-turn-banner")
    assert has_element?(view, "#log .msg-dm", @answer)
    view |> element("button[phx-click=pause]") |> render_click()
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-pc", @speech)
    assert Game.world(pid) == before
    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :narration and &1.actor == "Thane")) == 1
    refute Enum.any?(events, &(&1.type == :dice))
  end
end
