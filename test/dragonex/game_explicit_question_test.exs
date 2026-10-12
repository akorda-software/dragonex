defmodule Dragonex.GameExplicitQuestionTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Monsters, World}
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game(opts \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "La pregunta llega a quien debe responder",
        scene: "Un patio tranquilo después del encargo.",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), Keyword.get(opts, :wizard_kind, :ai)},
          {Archetypes.rogue(), :ai}
        ]
      )

    world = Keyword.get(opts, :change_world, &Function.identity/1).(Games.load_world(game))
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    game
  end

  defp boot(game, script, pc_scripts \\ %{}) do
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :explicit_question_tm)
          "(no decision)"
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: script}, turnmaster_model: tm]}}
      )

    for {name, script} <- pc_scripts do
      assert :ok == Server.set_model(:sys.get_state(pid).pc_agents[name], %Test{script: script})
    end

    pid
  end

  defp resume(pid) do
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
  end

  defp turns(game_id) do
    Games.list_events(game_id) |> Enum.filter(&(&1.type == :turn)) |> Enum.map(& &1.actor)
  end

  test "a literal vocative gives its companion one response when the human model never calls the tool" do
    game = game()
    parent = self()

    human = fn messages, _ ->
      send(parent, {:human_question_context, inspect(messages, limit: :infinity)})
      narration("—Vex, ¿puedes pedir agua a la posadera?")
    end

    response = fn messages, _ ->
      send(parent, {:vex_question_context, inspect(messages, limit: :infinity)})
      narration("—Posadera, ¿podría llenarme la jarra de agua?")
    end

    pid = boot(game, [human, narration("La posadera llena la jarra.")], %{"Vex" => [response]})
    resume(pid)
    before = Game.world(pid)
    question = "Vex, ¿puedes pedir agua a la posadera?"
    assert {:ok, :resolving} = Game.declare(pid, "Thane", question)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert turns(game.id) == ["Thane", "Vex", "dm"]
    assert_receive {:human_question_context, human_context}
    assert human_context =~ "Pregunta ya registrada"
    assert human_context =~ question
    assert_receive {:vex_question_context, response_context}
    assert response_context =~ "RESPONDER a Thane"
    assert response_context =~ question
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    refute_received :explicit_question_tm
  end

  test "the request is durable before a blocked human beat and model retries cannot replace it" do
    game = game()
    parent = self()
    question = "Vex y Lyra, ¿qué preferís observar aquí? Añado que sigo aquí."

    blocked = fn _, _ ->
      send(parent, {:human_question_blocked, self()})

      receive do
        :finish ->
          tool_calls([
            call("request_response", %{"recipients" => ["Lyra"], "question" => "Una paráfrasis."})
          ])
      after
        5_000 -> raise "human question was not released"
      end
    end

    pid =
      boot(
        game,
        [blocked, narration("—¿Qué preferís observar?"), narration("La posada está tranquila.")],
        %{
          "Vex" => [narration("—Yo miraría el patio.")],
          "Lyra" => [narration("—Yo estudiaría la luz.")]
        }
      )

    resume(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", question)
    assert_receive {:human_question_blocked, model_pid}, 2_000

    try do
      request = Game.world(pid).conversation
      assert request["recipients"] == ["Vex", "Lyra"]
      assert request["question"] == question
      assert Games.load_world(Games.get_game(game.id)).conversation == request
    after
      send(model_pid, :finish)
    end

    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert turns(game.id) == ["Thane", "Vex", "Lyra", "dm"]
    assert Game.world(pid).conversation == nil
    refute_received :explicit_question_tm
  end

  test "a queued declaration opens no request until consumed and then survives a human response restart" do
    game = game(wizard_kind: :human)
    pid = boot(game, [narration("—Lyra y Vex, ¿qué pensáis del patio?")])
    before = Game.world(pid)
    assert {:ok, :queued} = Game.declare(pid, "Thane", "Lyra y Vex, ¿qué pensáis del patio?")
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)).conversation == nil
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Lyra" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
    saved = Games.load_world(Games.get_game(game.id))
    assert saved.conversation["pending"] == ["Lyra", "Vex"]
    assert :ok == stop_supervised({Game, game.id})

    pid =
      boot(game, [narration("—Me gusta la sombra."), narration("La posada está tranquila.")], %{
        "Vex" => [narration("—Yo también.")]
      })

    assert Game.world(pid) == saved
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Lyra" and &1.status == :waiting), 5_000)
    assert {:ok, :resolving} = Game.declare(pid, "Lyra", "Vex, ¿compartimos la sombra?")
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert turns(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Game.world(pid) == before
    refute_received :explicit_question_tm
  end

  test "absent or incapacitated recipients do not become a partial conversation" do
    for change <- [
          fn world -> %{world | absent_characters: %{"Vex" => "Fuera del patio"}} end,
          fn world ->
            {:ok, world} = World.apply_condition("Vex", "stunned").(world)
            world
          end
        ] do
      game = game(change_world: change)
      parent = self()

      human = fn _, _ ->
        send(parent, {:unavailable_question_world, Games.load_world(Games.get_game(game.id))})
        narration("—Lyra y Vex, ¿qué pensáis?")
      end

      pid = boot(game, [human, narration("Thane, ¿qué quieres observar?")])
      resume(pid)
      before = Game.world(pid)
      assert {:ok, :resolving} = Game.declare(pid, "Thane", "Lyra y Vex, ¿qué pensáis?")
      assert_receive {:unavailable_question_world, world}, 2_000
      assert world.conversation == nil
      assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
      assert Game.world(pid) == before
      assert :ok == stop_supervised({Game, game.id})
    end
  end

  test "clearing a paused question prevents a response when the human resumes" do
    game = game()
    pid = boot(game, [])
    before = Game.world(pid)
    assert {:ok, :queued} = Game.declare(pid, "Thane", "Vex, ¿qué observas?")
    assert :ok == Game.clear_intent(pid, "Thane")
    resume(pid)
    assert Game.world(pid) == before
    assert Game.snapshot(pid).intents == %{}
    assert turns(game.id) == []
  end

  test "a failed human narrator still gives each explicitly requested companion one response" do
    game = game()
    parent = self()

    failed = fn ->
      send(parent, :explicit_human_narrator_failed)
      raise "human narrator failed"
    end

    pid =
      boot(game, [failed, narration("La posada está tranquila.")], %{
        "Vex" => [narration("—Yo miraría el patio.")]
      })

    resume(pid)
    before = Game.world(pid)

    assert {:ok, :resolving} =
             Game.declare(pid, "Thane", "Vex, ¿qué observas? Añado que sigo aquí.")

    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert turns(game.id) == ["Thane", "Vex", "dm"]
    assert_receive :explicit_human_narrator_failed
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute_received :explicit_question_tm
  end

  test "another person's queued intervention keeps its priority without losing the explicit recipient" do
    game = game(wizard_kind: :human)

    pid =
      boot(
        game,
        [
          narration("—Vex, ¿qué observas?"),
          narration("—Yo prefiero la sombra."),
          narration("La posada está tranquila.")
        ],
        %{
          "Vex" => [narration("—Yo miraría el patio.")]
        }
      )

    before = Game.world(pid)
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "Prefiero la sombra.")
    resume(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Vex, ¿qué observas?")
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert turns(game.id) == ["Thane", "Lyra", "Vex", "dm"]
    assert Game.snapshot(pid).intents == %{}
    assert Game.world(pid) == before
    refute_received :explicit_question_tm
  end

  test "an explicit question during combat opens no exploration request" do
    game =
      game(
        wizard_kind: :human,
        change_world: fn world ->
          {:ok, world} = World.add_character(Monsters.goblin(name: "g1")).(world)
          {:ok, world} = World.begin_combat(["Thane", "Lyra", "Vex", "g1"]).(world)
          {:ok, world} = World.set_current_combatant("Thane").(world)
          world
        end
      )

    parent = self()

    human = fn _, _ ->
      send(parent, {:combat_question_blocked, self()})

      receive do
        :finish -> narration("—Vex, ¿qué ves?")
      after
        5_000 -> raise "combat question was not released"
      end
    end

    pid = boot(game, [human])
    resume(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Vex, ¿qué ves?")
    assert_receive {:combat_question_blocked, model_pid}, 2_000

    try do
      world = Game.world(pid)
      assert world.phase == :combat
      assert world.current_combatant == "Thane"
      assert world.conversation == nil
      assert Games.load_world(Games.get_game(game.id)).conversation == nil
      assert :ok == Game.pause(pid)
    after
      send(model_pid, :finish)
    end

    assert :ok ==
             Game.await(pid, &(&1.status == :paused and :sys.get_state(pid).busy == nil), 5_000)

    assert Game.world(pid).phase == :combat
    assert Game.world(pid).conversation == nil
    assert "Thane" in Game.world(pid).acted_this_round
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Lyra" and &1.status == :waiting), 5_000)
    assert Game.world(pid).current_combatant == "Lyra"
    assert Game.world(pid).conversation == nil
    assert :ok == Game.pause(pid)
  end
end
