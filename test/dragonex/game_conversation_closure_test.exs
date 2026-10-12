defmodule Dragonex.GameConversationClosureTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @question "Lyra, Vex, ¿qué recordáis del combate? Espero vuestras respuestas antes de decidir."
  @speech "—Lyra, Vex, ¿qué recordáis del combate?"
  @multiple "Lyra, Vex, ¿qué cambia la última aclaración del zagal para nuestra pista del hilo? ¿Qué proponéis hacer ahora y por qué? Espero vuestras respuestas antes de decidir."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp dm do
    parent = self()

    fn messages, _ ->
      send(parent, {:closure_dm_request, ModelMessages.project(messages)})
      narration("Maribel responde desde la barra.")
    end
  end

  defp response(actor) do
    parent = self()

    fn messages, _ ->
      send(parent, {:closure_pc_request, actor, ModelMessages.project(messages)})
      narration("—Recuerdo la flecha.")
    end
  end

  defp boot(model, lyra \\ nil, opts \\ []) do
    wizard = %{
      Archetypes.wizard()
      | spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
    }

    {:ok, game} =
      Games.create_game(
        title: "Respuestas sin otro párrafo de ambiente",
        scene: "Maribel seca un cuenco junto a la barra.",
        roster:
          [{Archetypes.fighter(), :human}, {wizard, :ai}, {Archetypes.rogue(), :ai}] ++
            List.wrap(Keyword.get(opts, :extra_participant))
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :closure_tm_request)
          "(no decision)"
        end
      ]
    }

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        turnmaster_model: tm,
        roller: fn
          4 -> 1
          20 -> 10
        end
      )

    state = :sys.get_state(pid)

    assert :ok ==
             Server.set_model(state.pc_agents["Lyra"], %Test{script: lyra || [response("Lyra")]})

    assert :ok == Server.set_model(state.pc_agents["Vex"], %Test{script: [response("Vex")]})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before, List.last(Games.list_events(game.id)).seq}
  end

  defp finish(pid) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  defp new_events(game, seq), do: Enum.filter(Games.list_events(game.id), &(&1.seq > seq))

  test "a finished spoken exchange returns directly to its human without a DM or TM run" do
    {game, pid, before, seq} = boot(%Test{script: [dm()]})

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(pid)
      refute_received {:closure_dm_request, _}
      refute_received :closure_tm_request

      for actor <- ["Lyra", "Vex"] do
        assert_receive {:closure_pc_request, ^actor, wire}
        assert Enum.any?(wire, &ModelMessages.imported?(&1, @speech))
        assert Enum.any?(wire, &(&1["role"] == "system" and &1["content"] =~ "Eres #{actor},"))
      end

      events = new_events(game, seq)

      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert Enum.map(Enum.filter(events, &(&1.type == :narration)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute Enum.any?(events, &(&1.type == :dice))
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "restart while the first PC replies preserves proof and one speech per participant" do
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:closure_waiting, self()})
      receive do: (:finish -> narration("—Recuerdo la flecha."))
    end

    {game, pid, before, seq} = boot(%Test{script: [dm()]}, [blocked])

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      assert_receive {:closure_waiting, run}, 2_000
      assert :ok == Game.pause(pid)
      asked = Game.world(pid)
      assert is_map(asked.conversation["quiet_close"])
      assert Codec.decode(Codec.encode(asked)) == asked
      ref = Process.monitor(run)
      assert {:ok, fresh} = Game.restart(game.id, model: %Test{script: [dm()]})
      assert fresh != pid
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == asked
      state = :sys.get_state(fresh)

      for actor <- ["Lyra", "Vex"],
          do:
            assert(
              :ok == Server.set_model(state.pc_agents[actor], %Test{script: [response(actor)]})
            )

      assert :ok == Game.resume(fresh)
      finish(fresh)
      events = new_events(game, seq)

      assert Enum.map(Enum.filter(events, &(&1.type == :narration)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert Game.world(fresh) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute_received {:closure_dm_request, _}
      refute_received :closure_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a die with no world effect still retains the world response" do
    check =
      tool_calls([call("ability_check", %{"who" => "Lyra", "ability" => "int", "dc" => 10})])

    {game, pid, before, seq} = boot(%Test{script: [dm()]}, [check, response("Lyra")])

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(pid)
      assert_receive {:closure_dm_request, _}
      refute_received {:closure_dm_request, _}
      events = new_events(game, seq)
      assert Enum.count(events, &(&1.type == :dice)) == 1

      assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex",
               "dm"
             ]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute_received :closure_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a double question retains DM for a replying PC die or a new NPC question" do
    check =
      tool_calls([call("ability_check", %{"who" => "Lyra", "ability" => "int", "dc" => 10})])

    for {script, dice_count} <- [
          {[check, response("Lyra")], 1},
          {[narration("—Posadera, ¿puedes llenar la jarra de agua?")], 0}
        ] do
      {game, pid, before, seq} = boot(%Test{script: [dm(), dm()]}, script)

      try do
        assert {:ok, :resolving} == Game.declare(pid, "Thane", @multiple)
        finish(pid)
        assert_receive {:closure_dm_request, _}
        refute_received {:closure_dm_request, _}
        refute_received :closure_tm_request
        events = new_events(game, seq)
        assert Enum.count(events, &(&1.type == :dice)) == dice_count

        assert Enum.map(Enum.filter(events, &(&1.type == :turn)), & &1.actor) == [
                 "Thane",
                 "Lyra",
                 "Vex",
                 "dm"
               ]

        assert Game.world(pid) == before
        assert Games.load_world(Games.get_game(game.id)) == before
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end

  test "a spell cast by a replying PC pays once and retains the world response" do
    cast =
      tool_calls([
        call("cast_spell", %{"caster" => "Lyra", "target" => "Lyra", "spell" => "false life"})
      ])

    {game, pid, before, seq} = boot(%Test{script: [dm()]}, [cast, response("Lyra")])

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(pid)
      assert_receive {:closure_dm_request, _}
      refute_received {:closure_dm_request, _}
      after_reply = Game.world(pid)
      assert after_reply.spell_slots["Lyra"][1] == before.spell_slots["Lyra"][1] - 1
      assert after_reply.characters["Lyra"].temp_hp == 5
      assert after_reply.elapsed_seconds == before.elapsed_seconds
      assert after_reply.conversation == nil
      assert Games.load_world(Games.get_game(game.id)) == after_reply
      assert Enum.count(new_events(game, seq), &(&1.type == :dice)) == 1
      refute_received :closure_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a preference question preserves literal human speech without a human or DM request" do
    parent = self()

    human = fn messages, _ ->
      send(parent, {:closure_human_request, ModelMessages.project(messages)})
      narration("—Lyra, Vex, ¿qué preferís hacer ahora?")
    end

    {game, pid, before, seq} = boot(%Test{script: [human, dm()]})

    try do
      assert {:ok, :resolving} ==
               Game.declare(
                 pid,
                 "Thane",
                 "Lyra, Vex, ¿qué preferís hacer ahora? Espero vuestras respuestas antes de decidir."
               )

      finish(pid)
      refute_received {:closure_human_request, _}
      refute_received {:closure_dm_request, _}

      assert [%{payload: %{"text" => "—Lyra, Vex, ¿qué preferís hacer ahora?"}}] =
               Enum.filter(
                 new_events(game, seq),
                 &(&1.type == :narration and &1.actor == "Thane")
               )

      assert Enum.map(Enum.filter(new_events(game, seq), &(&1.type == :turn)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex"
             ]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute_received :closure_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "a requested NPC response survives a new question from the replying PC" do
    question = "—Posadera, ¿puedes llenar la jarra de agua?"
    {game, pid, before, seq} = boot(%Test{script: [dm()]}, [narration(question)])

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(pid)
      assert_receive {:closure_dm_request, wire}
      assert Enum.any?(wire, &ModelMessages.imported?(&1, question))

      assert Enum.map(Enum.filter(new_events(game, seq), &(&1.type == :turn)), & &1.actor) ==
               ["Thane", "Lyra", "Vex", "dm"]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute_received :closure_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "another human's queued declaration retains priority and the ordinary world response" do
    parent = self()

    blocked = fn _, _ ->
      send(parent, {:closure_priority_waiting, self()})
      receive do: (:finish -> narration("—Recuerdo la flecha."))
    end

    human = fn messages, _ ->
      send(parent, {:closure_priority_human, ModelMessages.project(messages)})
      narration("—Prefiero observar desde aquí.")
    end

    {game, pid, before, seq} =
      boot(%Test{script: [human, dm()]}, [blocked],
        extra_participant: {Archetypes.fighter(name: "Cora"), :human}
      )

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      assert_receive {:closure_priority_waiting, run}, 2_000
      assert {:ok, :queued} == Game.declare(pid, "Cora", "Prefiero observar desde aquí.")
      send(run, :finish)
      finish(pid)
      assert_receive {:closure_priority_human, wire}

      assert List.last(Enum.filter(wire, &(&1["role"] == "user")))["content"] =~
               "Estás resolviendo SOLO lo que Cora"

      assert_receive {:closure_dm_request, _}

      assert Enum.map(Enum.filter(new_events(game, seq), &(&1.type == :turn)), & &1.actor) ==
               ["Thane", "Lyra", "Cora", "Vex", "dm"]

      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      refute_received :closure_tm_request
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "an additional world clause and a failed response both keep their DM beat" do
    for {question, script} <- [
          {"Lyra, Vex, ¿qué recordáis del combate, y qué confirma la posadera? Espero vuestras respuestas antes de decidir.",
           [response("Lyra")]},
          {@question, [fn _, _ -> raise "scripted failed PC response" end]}
        ] do
      {game, pid, before, seq} = boot(%Test{script: [dm()]}, script)

      try do
        assert {:ok, :resolving} == Game.declare(pid, "Thane", question)
        finish(pid)
        assert_receive {:closure_dm_request, _}
        refute_received {:closure_dm_request, _}

        assert Enum.map(Enum.filter(new_events(game, seq), &(&1.type == :turn)), & &1.actor) == [
                 "Thane",
                 "Lyra",
                 "Vex",
                 "dm"
               ]

        assert Game.world(pid) == before
        assert Games.load_world(Games.get_game(game.id)) == before
        refute_received :closure_tm_request
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end
end
