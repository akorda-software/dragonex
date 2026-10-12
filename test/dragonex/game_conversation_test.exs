defmodule Dragonex.GameConversationTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Conversation, Game, Games, World}
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game(opts \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "Companions answer in their own voices",
        scene: "Una posada tranquila junto al puente.",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), Keyword.get(opts, :wizard_kind, :ai)},
          {Archetypes.rogue(), :ai}
        ]
      )

    world = Games.load_world(Games.get_game(game.id))
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    game
  end

  defp request(recipients \\ ["Lyra", "Vex"]) do
    tool_calls([
      call("request_response", %{
        "recipients" => recipients,
        "question" => "¿Qué sabéis del camino y qué pensáis del encargo?"
      })
    ])
  end

  defp boot(game, dm_script, pc_scripts) do
    owner = self()

    turnmaster = %Test{
      script: [
        fn _messages, _params ->
          send(owner, :conversation_tm_requested)
          "(no decision)"
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: dm_script}, turnmaster_model: turnmaster]}}
      )

    state = :sys.get_state(pid)

    for {name, script} <- pc_scripts do
      assert :ok == Server.set_model(state.pc_agents[name], %Test{script: script})
    end

    pid
  end

  defp start(game, dm_script, pc_scripts) do
    pid = boot(game, dm_script, pc_scripts)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    pid
  end

  defp actors(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.filter(&(&1.type == :narration and &1.payload["turn_id"] != nil))
    |> Enum.map(& &1.actor)
  end

  test "an explicit question gives both companions one real beat before the world and the human" do
    game = game()

    pid =
      start(
        game,
        [
          request(),
          narration("Thane pregunta a sus compañeros por el camino."),
          narration("La posada está en calma.")
        ],
        %{
          "Lyra" => [narration("—Prefiero estudiar el pergamino aquí antes de partir.")],
          "Vex" => [narration("—Yo vigilaría las huellas cerca del puente.")]
        }
      )

    before = Game.world(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex por el camino.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    after_world = Game.world(pid)
    assert after_world.characters == before.characters
    assert after_world.spell_slots == before.spell_slots
    assert after_world.elapsed_seconds == before.elapsed_seconds
    assert after_world.phase == :exploration
    assert after_world.conversation == nil
    assert Games.load_world(Games.get_game(game.id)) == after_world
    refute_receive :conversation_tm_requested
    refute Enum.any?(Games.list_events(game.id), &(&1.payload["note"] == "El turno pasa a dm."))
  end

  test "response agents see the literal question and their predecessor's real answer" do
    game = game()
    owner = self()

    observe = fn name, answer ->
      fn messages, _params ->
        send(owner, {:response_context, name, inspect(messages, limit: :infinity)})
        narration(answer)
      end
    end

    pid =
      start(
        game,
        [
          request(),
          narration("Thane pregunta por el camino."),
          narration("La posada está en calma.")
        ],
        %{
          "Lyra" => [observe.("Lyra", "—El sello del pergamino parece reciente.")],
          "Vex" => [observe.("Vex", "—Yo miraría primero el puente.")]
        }
      )

    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex por el camino.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert_receive {:response_context, "Lyra", lyra}
    assert lyra =~ "RESPONDER a Thane"
    assert lyra =~ "¿Qué sabéis del camino y qué pensáis del encargo?"
    assert lyra =~ "Pregunto a Lyra y Vex por el camino."
    assert_receive {:response_context, "Vex", vex}
    assert vex =~ "RESPONDER a Thane"
    assert vex =~ "El sello del pergamino parece reciente"
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
  end

  test "the resolver's gesture fixture cannot rewrite the human voice seen by the response agent" do
    raw = File.read!(Path.expand("../fixtures/narration/pc_iria_foreign_gesture.txt", __DIR__))
    game = game()
    owner = self()

    observe = fn messages, _params ->
      send(owner, {:clean_question_history, inspect(messages, limit: :infinity)})
      narration("—Yo estudiaría las luces desde aquí.")
    end

    pid =
      start(
        game,
        [request(), narration(raw), narration("La posada está en calma.")],
        %{
          "Lyra" => [observe],
          "Vex" => [narration("—Yo revisaría primero el puente.")]
        }
      )

    before = Game.world(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex por el camino.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert_receive {:clean_question_history, history}
    refute history =~ "sigue hojeando"
    refute history =~ "Luego giro la cabeza hacia Lyra."
    assert history =~ "Thane declara" and history =~ "Pregunto a Lyra y Vex por el camino."
    refute history =~ "qué te dice lo de las luces"

    narrated =
      game.id
      |> Games.list_events()
      |> Enum.filter(&(&1.type == :narration and &1.actor == "Thane"))
      |> Enum.map_join(" ", & &1.payload["text"])

    refute narrated =~ "sigue hojeando"
    refute narrated =~ "qué te dice lo de las luces"
    assert narrated == "Pregunto a Lyra y Vex por el camino."
    assert Game.world(pid).characters == before.characters
    assert Game.world(pid).spell_slots == before.spell_slots
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
  end

  test "an AI PC keeps its own opinion without supplying the next companion's gesture or reply" do
    game = game()
    owner = self()

    observe = fn messages, _params ->
      send(owner, {:companion_history, inspect(messages, limit: :infinity)})
      narration("—Yo vigilaría el puente.")
    end

    pid =
      start(
        game,
        [
          request(),
          narration("Thane pregunta por el camino."),
          narration("La posada está en calma.")
        ],
        %{
          "Lyra" => [
            narration("Alzo una ceja. «Yo estudiaría el mapa». Vex asiente. «Salgamos ya».")
          ],
          "Vex" => [observe]
        }
      )

    before = Game.world(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex por el camino.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert_receive {:companion_history, history}
    assert history =~ "Alzo una ceja"
    assert history =~ "Yo estudiaría el mapa"
    refute history =~ "Vex asiente"
    refute history =~ "Salgamos ya"

    lyra = Enum.find(Games.list_events(game.id), &(&1.type == :narration and &1.actor == "Lyra"))
    assert lyra.payload["text"] =~ "Yo estudiaría el mapa"
    refute lyra.payload["text"] =~ "Vex asiente"
    assert Game.world(pid).characters == before.characters
    assert Game.world(pid).spell_slots == before.spell_slots
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
  end

  test "a paused human recipient survives rehydration and answers only through their own declaration" do
    game = game(wizard_kind: :human)
    pid = start(game, [request(), narration("Thane pregunta por el camino.")], %{})
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Lyra"), 5_000)
    assert Game.world(pid).conversation["pending"] == ["Lyra", "Vex"]
    assert :ok == Game.pause(pid)
    saved = Games.load_world(Games.get_game(game.id))
    assert saved.conversation["pending"] == ["Lyra", "Vex"]
    assert :ok == stop_supervised({Game, game.id})

    pid =
      boot(
        game,
        [
          narration("—Yo estudiaría el pergamino antes de partir."),
          narration("La posada está en calma.")
        ],
        %{
          "Vex" => [narration("—Yo vigilaría el puente.")]
        }
      )

    assert Game.world(pid) == saved
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Lyra"), 5_000)

    assert {:ok, :resolving} =
             Game.declare(pid, "Lyra", "Estudiaría el pergamino antes de partir.")

    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Game.world(pid).conversation == nil

    assert Enum.map(Game.snapshot(pid).events |> Enum.filter(&(&1.type == :action)), & &1.actor) ==
             ["Thane", "Lyra"]
  end

  test "pausing after the first AI response persists only the remaining recipient" do
    game = game()
    owner = self()

    blocked = fn _messages, _params ->
      send(owner, {:response_waiting, self()})

      receive do
        :finish_response -> narration("—La ruta cruza el puente viejo.")
      after
        5_000 -> raise "response test was not released"
      end
    end

    pid =
      start(game, [request(), narration("Thane pregunta por el camino.")], %{"Lyra" => [blocked]})

    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex.")
    assert_receive {:response_waiting, task}, 2_000
    assert :ok == Game.pause(pid)
    send(task, :finish_response)
    assert :ok == Game.await(pid, &(&1.status == :paused and &1.current == "Vex"), 5_000)
    saved = Games.load_world(Games.get_game(game.id))
    assert saved.conversation["pending"] == ["Vex"]
    assert :ok == stop_supervised({Game, game.id})

    pid =
      boot(game, [narration("La posada está en calma.")], %{
        "Lyra" => [fn -> flunk("an already answered companion must not act again") end],
        "Vex" => [narration("—Yo vigilaría el puente.")]
      })

    assert Game.world(pid) == saved
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Games.load_world(Games.get_game(game.id)).conversation == nil
  end

  test "a failure after the committed question still delivers its pending responses once" do
    game = game()

    pid =
      start(game, [request(), fn -> raise "failure after the question committed" end], %{
        "Lyra" => [narration("—Yo estudiaría el pergamino aquí.")],
        "Vex" => [narration("—Yo vigilaría el puente.")]
      })

    before = Game.world(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert turns(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Game.world(pid).conversation == nil
    assert Game.world(pid).characters == before.characters
    assert Game.world(pid).spell_slots == before.spell_slots
  end

  test "a failed responder advances to the next companion without repeating their turn" do
    game = game()

    pid =
      start(
        game,
        [
          request(),
          narration("Thane pregunta por el camino."),
          narration("La posada está en calma.")
        ],
        %{
          "Lyra" => [fn -> raise "a failed response" end],
          "Vex" => [narration("—Yo vigilaría el puente.")]
        }
      )

    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert turns(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert "Vex" in actors(game.id)
    assert Game.world(pid).conversation == nil
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end

  test "a failed world closure returns the word to the human without repeating companions" do
    game = game()

    pid =
      start(
        game,
        [request(), narration("Thane pregunta por el camino."), fn -> raise "failed closure" end],
        %{
          "Lyra" => [narration("—Yo estudiaría el pergamino aquí.")],
          "Vex" => [narration("—Yo vigilaría el puente.")]
        }
      )

    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert turns(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Game.world(pid).conversation == nil
  end

  test "a queued unaddressed human acts first without losing the requested AI response" do
    game = game(wizard_kind: :human)

    pid =
      boot(
        game,
        [
          request(["Vex"]),
          narration("Thane pregunta a Vex por el camino."),
          narration("—Yo estudiaría el pergamino antes de partir."),
          narration("La posada está en calma.")
        ],
        %{
          "Vex" => [narration("—Yo vigilaría el puente.")]
        }
      )

    assert {:ok, :queued} = Game.declare(pid, "Lyra", "Estudiaría el pergamino antes de partir.")
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Vex por el camino.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert actors(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Game.snapshot(pid).intents == %{}
    assert Game.world(pid).conversation == nil
  end

  test "an AI questioner does not gain another automatic turn after the answers" do
    game = game()
    world = Games.load_world(Games.get_game(game.id))
    {:ok, _} = Games.save_state(game.id, world, "Lyra", world.round, :paused)

    pid =
      boot(game, [narration("Thane, ¿qué prefieres hacer con el pergamino?")], %{
        "Lyra" => [request(["Vex"]), narration("—¿Qué sabes del camino, Vex?")],
        "Vex" => [narration("—Yo vigilaría el puente.")]
      })

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert turns(game.id) == ["Lyra", "Vex", "dm"]
    assert Game.world(pid).conversation == nil
  end

  test "off-turn human re-evaluation keeps the waiting response and later honors the queued intervention" do
    game = game(wizard_kind: :human)

    pid =
      start(
        game,
        [
          request(),
          narration("Thane pregunta por el camino."),
          narration("—Yo estudiaría el pergamino aquí."),
          narration("Thane añade una observación sobre el puente."),
          narration("La posada está en calma.")
        ],
        %{"Vex" => [narration("—Yo vigilaría el puente.")]}
      )

    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Pregunto a Lyra y Vex.")
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Lyra"), 5_000)

    assert {:ok, :queued} =
             Game.declare(pid, "Thane", "Añado que las piedras del puente parecen húmedas.")

    assert_receive :conversation_tm_requested, 2_000
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Lyra"), 5_000)
    assert Game.world(pid).conversation["pending"] == ["Lyra", "Vex"]

    assert Game.snapshot(pid).intents["Thane"] ==
             "Añado que las piedras del puente parecen húmedas."

    assert {:ok, :resolving} = Game.declare(pid, "Lyra", "Estudiaría el pergamino aquí.")

    assert :ok ==
             Game.await(
               pid,
               &(&1.status == :waiting and &1.current == "Thane" and &1.intents == %{}),
               5_000
             )

    assert actors(game.id) == ["Thane", "Lyra", "Thane", "Vex", "dm"]
    assert Game.world(pid).conversation == nil
  end

  test "unavailable recipients are skipped before handoff and do not trigger a death save" do
    game = game()
    world = Games.load_world(Games.get_game(game.id))

    {:ok, world} =
      Conversation.request("Thane", ["Lyra", "Vex"], "¿Qué pensáis del camino?").(world)

    {:ok, world} = World.apply_damage("Lyra", 99).(world)
    # The already committed question can be interrupted by a later effect.
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)

    pid =
      start(
        game,
        [narration("Thane termina su pregunta."), narration("La posada está en calma.")],
        %{
          "Lyra" => [fn -> flunk("an unconscious PC cannot answer") end],
          "Vex" => [narration("—Yo vigilaría el puente.")]
        }
      )

    assert {:ok, :resolving} =
             Game.declare(pid, "Thane", "Pregunto a mis compañeros por el camino.")

    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert turns(game.id) == ["Thane", "Vex", "dm"]
    assert Game.world(pid).characters["Lyra"].death_saves == %{successes: 0, fails: 0}
  end

  defp turns(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.filter(&(&1.type == :turn))
    |> Enum.map(& &1.actor)
  end

  test "rehydrating on an unconscious recipient skips that response before launching its agent" do
    game = game()
    world = Games.load_world(Games.get_game(game.id))

    {:ok, world} =
      Conversation.request("Thane", ["Lyra", "Vex"], "¿Qué pensáis del camino?").(world)

    {:ok, world} = World.apply_damage("Lyra", 99).(world)
    {:ok, _} = Games.save_state(game.id, world, "Lyra", world.round, :paused)

    pid =
      boot(game, [narration("La posada está en calma.")], %{
        "Lyra" => [fn -> flunk("an unconscious recipient must be skipped before its beat") end],
        "Vex" => [narration("—Yo vigilaría el puente.")]
      })

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert turns(game.id) == ["Vex", "dm"]
    assert Game.world(pid).characters["Lyra"].death_saves == %{successes: 0, fails: 0}
    assert Game.world(pid).conversation == nil
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end
end
