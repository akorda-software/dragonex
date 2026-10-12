defmodule DragonexWeb.GameNPCRecipientTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}

  @sample File.read!(Path.expand("../fixtures/narration/pc_vex_npc_recipient.txt", __DIR__))
          |> String.trim()

  test "the NPC recipient remains visible in the PC's preview and persisted delivery" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "recipient-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Una voz completa"
      })

    {:ok, game} =
      Games.create_game(
        title: "El saquito llega a la posadera",
        user_id: user.id,
        roster: [{Archetypes.wizard(name: "Mara de la Bruma"), :human}, {Archetypes.rogue(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Vex", before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, {:recipient_response_ready, self()})

          receive do
            :finish -> narration(@sample)
          after
            5_000 -> raise "response was not released"
          end
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Dragonex.Test.Narrator{text: "La taberna sigue tranquila."}]}}
      )

    assert :ok == Server.set_model(:sys.get_state(pid).pc_agents["Vex"], model)
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert_receive {:recipient_response_ready, model_pid}, 1_000

    try do
      turn_id = :sys.get_state(pid).busy.turn_id
      send(view.pid, {:text_delta, game.id, turn_id, "Vex", @sample})
      assert has_element?(view, ".live-streaming", @sample)
    after
      send(model_pid, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == "Mara de la Bruma" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-pc", @sample)
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
