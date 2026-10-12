defmodule DragonexWeb.GameNPCObservationQuestionTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Accounts, Archetypes, Game, Games}
  alias ExAgent.Models.Test

  @question "Le pregunto a la posadera: «¿Viste tú misma marcharse al forastero o te lo contó alguien?» Espero aquí su respuesta."
  @speech "—¿Viste tú misma marcharse al forastero o te lo contó alguien?"
  @claim "Lo vi salir, pero no vi qué camino tomó."
  @answer "Maribel responde. —Lo vi salir, pero no vi qué camino tomó."

  test "the exact observation question appears before the NPC answers and attributed memory survives reload" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "observation-npc-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Una pregunta sin gestos añadidos"
      })

    {:ok, game} =
      Games.create_game(
        title: "La fuente del rumor",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    initial_events = Games.list_events(game.id)
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:observation_npc_ready, self(), inspect(messages, limit: :infinity)})

          receive do
            :finish ->
              tool_calls([
                call("record_npc_statement", %{"speaker" => "Maribel", "statement" => @claim})
              ])
          end
        end,
        narration(@answer)
      ]
    }

    unexpected = fn _, _ ->
      send(parent, :observation_auxiliary_called)
      "No hace falta."
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        turnmaster_model: %Test{script: [unexpected]},
        scene_model: %Test{script: [unexpected]}
      )

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    view |> element("button[phx-click=resume]") |> render_click()
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    view |> element("#player-input") |> render_submit(%{"text" => @question})
    assert_receive {:observation_npc_ready, run, context}, 2_000

    try do
      assert context =~ "Responde como ese PNJ"
      refute context =~ "Estás resolviendo SOLO lo que Thane"
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
    assert has_element?(reloaded, "#log .msg-dm", @answer)
    after_world = Game.world(pid)

    assert after_world.facts == [
             "Maribel afirma: «#{@claim}» [Registrado a los 0 s del reloj del mundo.]"
           ]

    assert Map.drop(before, [:facts]) == Map.drop(after_world, [:facts])
    assert Games.load_world(Games.get_game(game.id)) == after_world
    all_events = Games.list_events(game.id)
    assert Enum.take(all_events, length(initial_events)) == initial_events
    events = Enum.drop(all_events, length(initial_events))

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "Thane" and &1.payload["text"] == @speech)
           ) == 1

    assert Enum.count(events, &(&1.type == :narration and &1.actor == "dm")) == 1
    refute Enum.any?(events, &(&1.type == :dice))
    refute_received :observation_auxiliary_called
  end
end
