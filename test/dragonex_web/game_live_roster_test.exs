defmodule DragonexWeb.GameLiveRosterTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  test "the table learns a same-beat character before its narration starts streaming" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "live-roster-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Voces"
      })

    pc = Archetypes.wizard(name: "Lyra")

    {:ok, game} =
      Games.create_game(title: "Una nueva voz", user_id: user.id, roster: [{pc, :human}])

    {:ok, _} = Games.save_state(game.id, Games.load_world(game), "dm", 1, :paused)
    parent = self()
    new_name = "Lyra del Muelle"
    raw = "«Volved al amanecer», dice #{new_name}. «Aceptamos», dice Lyra."

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, {:model_ready, self()})

          receive do
            :create_character ->
              tool_calls([call("spawn_monster", %{"kind" => "bandit", "name" => new_name})])
          after
            5_000 -> raise "creation was not released"
          end
        end,
        fn _, _ ->
          send(parent, {:character_committed, self()})

          receive do
            :finish_narration -> narration(raw)
          after
            5_000 -> raise "narration was not released"
          end
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: model, roller: fixed_roller(10)]}}
      )

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert_receive {:model_ready, model_pid}, 1_000

    Phoenix.PubSub.broadcast(
      Dragonex.PubSub,
      "dragonex:game:#{game.id}",
      {:game_updated, game.id}
    )

    refute render(view) =~ new_name
    send(model_pid, :create_character)
    assert_receive {:character_committed, narration_pid}, 1_000

    try do
      assert Game.world(pid).characters[new_name]
      assert has_element?(view, ".card-name", new_name)
      turn_id = :sys.get_state(pid).busy.turn_id
      send(view.pid, {:text_delta, game.id, turn_id, "dm", raw})
      assert has_element?(view, ".live-streaming", "Volved al amanecer")
      assert has_element?(view, ".live-streaming", "dice #{new_name}")
      refute has_element?(view, ".live-streaming", "Aceptamos")
    after
      send(narration_pid, :finish_narration)
    end

    assert :ok = Game.await(pid, &(&1.current == pc.name and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, "#log .msg-dm", "Volved al amanecer")
    refute has_element?(reloaded, "#log .msg-dm", "Aceptamos")
  end
end
