defmodule Dragonex.GameNarrationContractTest.SequenceModel do
  @behaviour ExAgent.Model
  defstruct [:counter]

  @impl true
  def request(model, messages, _settings, params) do
    next =
      Agent.get_and_update(model.counter, fn
        [item | rest] -> {item, rest}
        [] -> {{:error, :script_exhausted}, []}
      end)

    item = if is_function(next, 2), do: next.(messages, params), else: next

    case item do
      {:error, _} = error -> error
      %ExAgent.Message.Response{} = response -> {:ok, response, model}
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:ok, response, updated} -> [Dragonex.Test.Harness.stream_response(response, updated)]
      {:error, reason} -> [{:error, reason}]
    end
  end

  @impl true
  def model_name(_), do: "narration-sequence"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: ExAgent.Models.Test.profile(%ExAgent.Models.Test{})
end

defmodule Dragonex.GameNarrationContractTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [call: 2, tool_calls: 1]
  alias Dragonex.{Archetypes, Game, Games, History, Monsters, World}
  alias Dragonex.Test.ModelMessages
  alias ExAgent.{Message, Models.Test}
  alias ExAgent.Message.Part

  @private "I need to consider the tools and decide which output to emit."
  @scene "El patio tiene una mesa de roble."
  @public "Thane, ¿qué observas en el patio?"
  @declaration "Ataco al goblin con mi espada larga y digo: «Atrás»."

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(
        title: "Narración real validada",
        roster: [{Archetypes.fighter(), :human}]
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    %{game: game, world: world}
  end

  defp final(text \\ @public), do: call("final_result", %{"text" => text})

  defp sequence(items) do
    counter = start_supervised!({Agent, fn -> items end})
    %Dragonex.GameNarrationContractTest.SequenceModel{counter: counter}
  end

  defp response(calls),
    do: Message.new_response([%Part.Text{content: @private} | calls], finish_reason: :tool_calls)

  defp scene_model, do: %Test{script: [tool_calls([call("final_result", %{"scene" => @scene})])]}

  defp opts(model, extra \\ []) do
    Keyword.merge(
      [
        model: model,
        scene_model: scene_model(),
        roller: fn sides -> flunk("unexpected d#{sides}") end,
        turnmaster_model: %Test{
          script: [tool_calls([call("give_turn_to", %{"participant" => "Thane"})]), "Listo."]
        }
      ],
      extra
    )
  end

  defp boot(game, model, extra \\ []),
    do: Dragonex.Test.GameFixture.start!({Game, {game.id, opts(model, extra)}})

  defp boot_durable(game, model, extra \\ []) do
    {:ok, pid} = Game.ensure_started(game.id, opts(model, extra))
    start_supervised!({Dragonex.Test.GameFixture, pid})
    on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
    pid
  end

  defp intercept_narrate(pid, callback) do
    tool = %{Dragonex.Narration.tool() | call: callback} |> Dragonex.Game.ToolReplay.wrap()

    :sys.replace_state(:sys.get_state(pid).dm, fn server ->
      tools = Enum.map(server.agent.tools, &if(&1.name == "narrate", do: tool, else: &1))
      %{server | agent: %{server.agent | tools: tools}}
    end)
  end

  defp finish(pid),
    do: assert(:ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5000))

  defp narration(game),
    do:
      Enum.filter(
        Games.list_events(game.id),
        &(&1.type == :narration and &1.payload["turn_id"] != nil)
      )

  test "default DM preserves explicit intermediate speech and only publishes validated final prose",
       %{game: game, world: before} do
    declaration = "La puerta de la torre está abierta."

    script = [
      response([call("narrate", %{"text" => declaration})]),
      response([call("set_scene", %{"narration" => @scene})]),
      response([final()])
    ]

    pid = boot(game, %Test{script: script})
    :ok = Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game.id}")
    assert :ok == Game.resume(pid)
    finish(pid)
    assert :ok == Game.pause(pid)

    assert [
             %{payload: %{"text" => ^declaration, "complete" => false}},
             %{payload: %{"text" => @public, "complete" => true}}
           ] = narration(game)

    assert Game.world(pid).scene == @scene
    assert Game.world(pid).characters == before.characters
    assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 0

    refute inspect(History.import_events(Games.list_events(game.id)) |> ModelMessages.project()) =~
             @private

    refute_received {:text_delta, _, _, _, _}
  end

  test "blank intermediate speech publishes nothing and cannot exhaust the turn (19463)",
       %{game: game, world: before} do
    blanks =
      for text <- ["", "  ", "\n", "", " "],
          do: response([call("narrate", %{"text" => text})])

    pid = boot(game, %Test{script: blanks ++ [response([final()])]})
    assert :ok == Game.resume(pid)
    finish(pid)
    assert :ok == Game.pause(pid)
    assert [%{payload: %{"text" => @public, "complete" => true}}] = narration(game)
    refute Enum.any?(Games.list_events(game.id), &(&1.payload["kind"] == "turn_failed"))
    assert Game.world(pid).characters == before.characters
  end

  test "a mixed output is retried without executing its omitted world tool", %{
    game: game,
    world: before
  } do
    owner = self()

    script = [
      response([final(), call("set_scene", %{"narration" => @scene})]),
      fn messages, params ->
        send(owner, {:corrective_narration_request, messages, params})
        response([final()])
      end
    ]

    pid = boot(game, %Test{script: script})
    assert :ok == Game.resume(pid)
    finish(pid)
    assert :ok == Game.pause(pid)
    assert_receive {:corrective_narration_request, messages, params}
    assert inspect(messages) =~ "final_result"
    assert inspect(messages) =~ "aislada"
    assert Enum.any?(params.output_tools, &(&1.name == "final_result"))
    assert [%{payload: %{"text" => @public, "complete" => true}}] = narration(game)
    assert Game.world(pid).scene == before.scene
    assert Game.world(pid).characters == before.characters
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end

  test "a token-limit retry preserves explicit speech and replays its receipt once", %{
    game: game,
    world: before
  } do
    declaration = "La puerta de la torre está abierta."
    speech = call("narrate", %{"text" => declaration})
    scene = call("set_scene", %{"narration" => @scene})

    model =
      sequence([
        response([speech]),
        response([scene]),
        Message.new_response([%Part.Text{content: @private}], finish_reason: :length),
        response([speech]),
        response([scene]),
        response([final()])
      ])

    pid = boot(game, model)
    assert :ok == Game.resume(pid)
    finish(pid)
    assert :ok == Game.pause(pid)

    assert [
             %{payload: %{"text" => ^declaration, "complete" => false}},
             %{payload: %{"text" => @public, "complete" => true}}
           ] = narration(game)

    assert Game.world(pid).scene == @scene
    assert Game.world(pid).characters == before.characters
    assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
    assert Game.world(pid).actor_checkpoint == nil
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 0
  end

  test "a large native truncated response retries its cause and preserves the paid inventory receipt",
       %{game: game, world: before} do
    item = "campanilla de cobre de Berta"
    fact = "El encargo de Berta está cerrado; su campanilla ha sido devuelta."
    public = "Berta recoge su campanilla; el encargo queda cerrado."
    private = String.duplicate("private deliberation ", 300)
    {:ok, stocked} = World.grant_item("Thane", item, 1).(before)
    {:ok, _} = Games.save_state(game.id, stocked, "dm", stocked.round, :paused)
    remove = call("remove_item", %{"who" => "Thane", "item" => item, "quantity" => 1})

    partial =
      Message.new_response([%Part.Text{content: private}, remove], finish_reason: :length)

    failure = %ExAgent.RequestError{
      provider: :openrouter,
      reason: {:incomplete_response, :length},
      partial_response: partial
    }

    assert :erlang.external_size({:model_request_failed, failure}) > 4096
    owner = self()

    model =
      sequence([
        response([remove]),
        {:error, failure},
        fn messages, params ->
          send(owner, {:inventory_token_retry, messages, params})
          response([remove])
        end,
        response([call("establish_fact", %{"fact" => fact})]),
        response([final(public)])
      ])

    pid = boot(game, model)
    tool = Enum.find(Dragonex.DM.tools(), &(&1.name == "remove_item"))

    observed =
      %{
        tool
        | call: fn ctx, args ->
            send(owner, {:paid_inventory_remove, args})
            tool.call.(ctx, args)
          end
      }
      |> Dragonex.Game.ToolReplay.wrap()

    :sys.replace_state(:sys.get_state(pid).dm, fn server ->
      tools =
        Enum.map(server.agent.tools, &if(&1.name == "remove_item", do: observed, else: &1))

      %{server | agent: %{server.agent | tools: tools}}
    end)

    assert :ok == Game.resume(pid)
    finish(pid)
    assert :ok == Game.pause(pid)

    assert_receive {:paid_inventory_remove, %{"who" => "Thane", "item" => ^item, "quantity" => 1}}

    refute_receive {:paid_inventory_remove, _}, 0
    assert_receive {:inventory_token_retry, messages, params}
    refute inspect(ModelMessages.project(messages)) =~ private
    assert params.allow_text_output == false
    assert [%{payload: %{"text" => ^public, "complete" => true}}] = narration(game)
    assert Game.world(pid).characters == before.characters
    assert Enum.count(Game.world(pid).facts, &(&1 == fact)) == 1
    assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
    assert Game.world(pid).actor_checkpoint == nil
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
    events = Games.list_events(game.id)
    refute Enum.any?(events, &String.contains?(&1.payload["note"] || "", "el turno falló"))
    refute inspect(events) =~ private
    assert Enum.count(events, &(&1.type == :dice)) == 0
  end

  for flag <- [:length, :content_filter, :unknown, :incomplete, :error] do
    test "#{flag} output never completes a turn and pauses with a recoverable checkpoint", %{
      game: game,
      world: before
    } do
      invalid = Message.new_response([final()], finish_reason: unquote(flag))
      pid = boot(game, sequence([invalid, invalid]))
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status == :paused), 5000)
      assert :sys.get_state(pid).busy == nil
      pending = Game.world(pid)
      assert pending.actor_checkpoint["pending_narration"] == true
      assert pending.actor_checkpoint["tools"] == []
      assert pending.characters == before.characters
      assert pending.elapsed_seconds == before.elapsed_seconds
      assert Games.completed_narration(game.id, "dm", pending.actor_checkpoint["turn_id"]) == nil
      assert narration(game) == []
      assert Games.load_world(Games.get_game(game.id)) == pending
    end
  end

  for kind <- [:mixed, :length] do
    test "a #{kind} failure arriving after manual pause cannot restart narration", %{
      game: game,
      world: before
    } do
      owner = self()

      invalid =
        if unquote(kind) == :mixed,
          do: response([final(), call("set_scene", %{"narration" => @scene})]),
          else: Message.new_response([final()], finish_reason: :length)

      model = %Test{
        script: [
          fn _, _ ->
            send(owner, {:closure_before_pause, self()})
            receive do: (:finish -> invalid)
          end,
          fn _, _ ->
            send(owner, :unexpected_closure_retry_after_pause)
            response([final()])
          end
        ]
      }

      pid = boot(game, model)
      assert :ok == Game.resume(pid)
      assert_receive {:closure_before_pause, request}, 2000
      assert :ok == Game.pause(pid)
      send(request, :finish)

      assert :ok ==
               Game.await(
                 pid,
                 fn snap -> snap.status == :paused and :sys.get_state(pid).busy == nil end,
                 5000
               )

      refute_received :unexpected_closure_retry_after_pause
      assert narration(game) == []
      pending = Game.world(pid)
      assert pending.actor_checkpoint["pending_narration"] == true
      assert pending.characters == before.characters
      assert pending.scene == before.scene
      assert pending.elapsed_seconds == before.elapsed_seconds
      assert Games.get_game(game.id).status == :paused
      assert Games.load_world(Games.get_game(game.id)) == pending
    end
  end

  test "an AI PC publishes its own explicit declaration and validated closure through the default agent" do
    {:ok, game} =
      Games.create_game(
        title: "Vex tiene voz propia",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.rogue(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Vex", before.round, :paused)
    declaration = "—Vigilaré el patio mientras decides qué buscar."
    closure = "—Thane, ¿quieres que examine la cerradura?"

    model = %Test{
      script: [response([call("narrate", %{"text" => declaration})]), response([final(closure)])]
    }

    pid = boot(game, model)

    assert :ok ==
             ExAgent.Server.set_model(:sys.get_state(pid).dm, %Test{script: [response([final()])]})

    assert :ok == Game.resume(pid)
    finish(pid)
    assert :ok == Game.pause(pid)

    assert [
             %{payload: %{"text" => ^declaration, "complete" => false}},
             %{payload: %{"text" => ^closure, "complete" => true}}
           ] = Enum.filter(narration(game), &(&1.actor == "Vex"))

    assert Game.world(pid).characters == before.characters
    assert Game.world(pid).elapsed_seconds == before.elapsed_seconds
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)

    refute inspect(History.import_events(Games.list_events(game.id)) |> ModelMessages.project()) =~
             @private
  end

  test "a parked provider retry keeps the exhausted closure budget and cannot loop forever", %{
    game: game,
    world: before
  } do
    previous = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [60_000])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dragonex, :transient_backoffs, previous),
        else: Application.delete_env(:dragonex, :transient_backoffs)
    end)

    mixed = response([final(), call("set_scene", %{"narration" => @scene})])
    failure = %ExAgent.RequestError{provider: :openrouter, status: 503, reason: :http_error}
    model = sequence([mixed, {:error, failure}, mixed])
    pid = boot(game, model)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.busy_stage == :retrying), 5000)
    pending = :sys.get_state(pid).busy
    assert %Dragonex.Game.PendingRetry{narration_retries: 1, transient_retries: 1} = pending
    send(pid, {:retry_beat, pending.turn_id})
    assert :ok == Game.await(pid, &(&1.status == :paused), 5000)
    assert :sys.get_state(pid).busy == nil
    world = Game.world(pid)
    assert world.actor_checkpoint["turn_id"] == pending.turn_id
    assert world.actor_checkpoint["pending_narration"] == true
    assert world.scene == before.scene
    assert world.characters == before.characters
    assert narration(game) == []
    assert Agent.get(model.counter, & &1) == []
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "a typed wait closure must resolve the clock before publishing its final speech", %{
    game: game,
    world: before
  } do
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    premature = "La espera termina junto a la puerta."
    declaration = "Espero cinco minutos aquí sin descansar."
    advance = call("advance_time", %{"seconds" => 300})

    model = %Test{
      script: [
        response([final(premature)]),
        response([advance]),
        response([advance]),
        response([final()])
      ]
    }

    pid = boot(game, model)
    assert :ok == Game.resume(pid)
    finish(pid)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", declaration)
    finish(pid)
    assert :ok == Game.pause(pid)
    world = Game.world(pid)
    assert world.elapsed_seconds == before.elapsed_seconds + 300
    assert world.wait_resolution["elapsed_seconds"] == 300
    assert world.characters == before.characters
    assert world.spell_slots == before.spell_slots
    assert world.rest_state == before.rest_state
    refute Enum.any?(narration(game), &(&1.payload["text"] == premature))

    assert [%{payload: %{"text" => @public, "complete" => true}}] =
             Enum.filter(narration(game), &(&1.actor == "dm"))

    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 0
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "restart between public intermediate speech and tool acknowledgement replays its saved receipt",
       %{
         game: game,
         world: before
       } do
    owner = self()
    declaration = "La puerta de la torre está abierta."
    script = [response([call("narrate", %{"text" => declaration})]), response([final()])]
    pid = boot_durable(game, %Test{script: script})

    intercept_narrate(pid, fn ctx, args ->
      result = Dragonex.Narration.Contract.publish_intermediate(args, ctx.deps)
      send(owner, {:intermediate_published, self(), result})
      receive do: (:finish -> {:ok, "Narración pública registrada; el turno sigue abierto."})
    end)

    assert :ok == Game.resume(pid)
    assert_receive {:intermediate_published, tool, {:ok, ^declaration}}, 2000
    monitor = Process.monitor(tool)
    assert :ok == Game.pause(pid)
    saved = Game.world(pid)
    assert is_map(saved.actor_checkpoint)
    turn = saved.actor_checkpoint["turn_id"]
    assert [%{"name" => "narrate", "values" => [_]}] = saved.actor_checkpoint["tools"]
    assert Map.drop(saved, [:actor_checkpoint]) == Map.drop(before, [:actor_checkpoint])
    assert Games.load_world(Games.get_game(game.id)) == saved
    assert Games.completed_narration(game.id, "dm", turn) == nil
    assert {:ok, fresh} = Game.restart(game.id, opts(%Test{script: script}))
    start_supervised!({Dragonex.Test.GameFixture, fresh})
    assert_receive {:DOWN, ^monitor, :process, ^tool, _}, 1000
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert :ok == Game.pause(fresh)

    assert [
             %{payload: %{"text" => ^declaration, "complete" => false}},
             %{payload: %{"text" => @public, "complete" => true}}
           ] = narration(game)

    assert Games.completed_narration(game.id, "dm", turn) == @public
    assert Game.world(fresh).actor_checkpoint == nil
    assert Enum.count(Games.list_events(game.id), &(&1.type == :turn and &1.actor == "dm")) == 1
  end

  test "a final response without rule tools retains its turn until scene review settles", %{
    game: game,
    world: before
  } do
    owner = self()
    before = %{before | scene_refresh_pending: true}
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)

    recorder = %Test{
      script: [
        fn _, _ ->
          send(owner, {:final_only_review, self()})
          receive do: (:finish -> tool_calls([call("final_result", %{"scene" => @scene})]))
        end
      ]
    }

    pid = boot_durable(game, %Test{script: [response([final()])]}, scene_model: recorder)
    assert :ok == Game.resume(pid)
    assert_receive {:final_only_review, recording}, 2000
    monitor = Process.monitor(recording)
    assert :ok == Game.pause(pid)
    saved = Game.world(pid)
    assert is_map(saved.actor_checkpoint)
    assert saved.actor_checkpoint["tools"] == []
    turn = saved.actor_checkpoint["turn_id"]
    assert Games.completed_narration(game.id, "dm", turn) == @public
    unused = %Test{script: [fn -> flunk("a completed response must not be requested again") end]}
    assert {:ok, fresh} = Game.restart(game.id, opts(unused))
    start_supervised!({Dragonex.Test.GameFixture, fresh})
    assert_receive {:DOWN, ^monitor, :process, ^recording, _}, 1000
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert :ok == Game.pause(fresh)
    assert [%{payload: %{"text" => @public, "complete" => true}}] = narration(game)
    assert Game.world(fresh).scene == @scene
    assert Game.world(fresh).characters == before.characters
    assert Game.world(fresh).actor_checkpoint == nil
    assert Games.load_world(Games.get_game(game.id)) == Game.world(fresh)
    assert Enum.count(Games.list_events(game.id), &(&1.type == :turn and &1.actor == "dm")) == 1
  end

  test "SQL rejection rolls back intermediate speech and its receipt before Session or PubSub", %{
    game: game,
    world: before
  } do
    owner = self()
    declaration = "La puerta de la torre está abierta."

    model = %Test{
      script: [response([call("narrate", %{"text" => declaration})]), response([final()])]
    }

    pid = boot_durable(game, model)

    intercept_narrate(pid, fn ctx, args ->
      send(owner, {:before_speech_commit, self()})
      receive do: (:commit -> :ok)

      send(
        owner,
        {:speech_commit_result, Dragonex.Narration.Contract.publish_intermediate(args, ctx.deps)}
      )

      receive do: (:retry -> :ok)

      send(
        owner,
        {:speech_retry_result, Dragonex.Narration.Contract.publish_intermediate(args, ctx.deps)}
      )

      receive do: (:finish -> {:ok, "Narración pública registrada; el turno sigue abierto."})
    end)

    assert :ok == Game.resume(pid)
    assert_receive {:before_speech_commit, tool}, 2000
    assert :ok == Game.pause(pid)
    events = Games.list_events(game.id)
    :ok = Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game.id}")

    Ecto.Adapters.SQL.query!(
      Dragonex.Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_narration_checkpoint CHECK (game_id <> #{game.id} OR type <> 'narration' OR payload->>'turn_id' IS NULL)",
      []
    )

    send(tool, :commit)

    assert_receive {:speech_commit_result, {:error, {:narration_contract, :persistence_failed}}},
                   2000

    assert Process.alive?(pid)
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Games.list_events(game.id) == events
    refute_receive {:game_updated, _}, 20

    Ecto.Adapters.SQL.query!(
      Dragonex.Repo,
      "ALTER TABLE game_events DROP CONSTRAINT reject_test_narration_checkpoint",
      []
    )

    send(tool, :retry)
    assert_receive {:speech_retry_result, {:ok, ^declaration}}, 2000
    saved = Game.world(pid)
    assert Map.drop(saved, [:actor_checkpoint]) == Map.drop(before, [:actor_checkpoint])
    assert [%{"name" => "narrate", "values" => [_]}] = saved.actor_checkpoint["tools"]
    assert Games.load_world(Games.get_game(game.id)) == saved
    assert [%{payload: %{"text" => ^declaration, "complete" => false}}] = narration(game)
    assert_receive {:game_updated, _}, 500
    send(tool, :finish)
    assert :ok == Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end, 5000)
    assert Game.world(pid).actor_checkpoint == nil
    assert Enum.count(narration(game), &(&1.payload["text"] == declaration)) == 1
  end

  test "rejected closure pauses with an empty durable checkpoint and restarts the same DM turn",
       %{game: game, world: before} do
    mixed = response([final(), call("set_scene", %{"narration" => @scene})])
    pid = boot_durable(game, %Test{script: [mixed, mixed]})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :paused), 5000)
    assert :sys.get_state(pid).busy == nil
    pending = Game.world(pid)
    assert pending.scene == before.scene
    assert pending.characters == before.characters
    assert pending.actor_checkpoint["pending_narration"] == true
    assert pending.actor_checkpoint["tools"] == []
    turn = pending.actor_checkpoint["turn_id"]
    assert Games.completed_narration(game.id, "dm", turn) == nil
    assert narration(game) == []
    assert Games.load_world(Games.get_game(game.id)) == pending
    assert {:ok, fresh} = Game.restart(game.id, opts(%Test{script: [response([final()])]}))
    start_supervised!({Dragonex.Test.GameFixture, fresh})
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert :ok == Game.pause(fresh)
    assert Games.completed_narration(game.id, "dm", turn) == @public
    assert Enum.count(Games.list_events(game.id), &(&1.type == :turn and &1.actor == "dm")) == 1
    assert Game.world(fresh).actor_checkpoint == nil
  end

  test "unstructured manual output pauses and preserves its original declaration before any rule effect",
       %{game: game, world: before} do
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    pid = boot_durable(game, %Test{label: @private})
    assert :ok == Game.resume(pid)
    finish(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @declaration)
    assert :ok == Game.await(pid, &(&1.status == :paused), 5000)
    assert :sys.get_state(pid).busy == nil
    pending = Game.world(pid)
    assert pending.characters == before.characters
    assert pending.actor_checkpoint["pending_narration"] == true
    turn = pending.actor_checkpoint["turn_id"]
    assert Games.declaration_for_turn(game.id, "Thane", turn) == @declaration
    assert Games.completed_narration(game.id, "Thane", turn) == nil
    assert narration(game) == []
    # This is an acknowledgement of the original unresolved intent, never a
    # mechanical attack receipt. A later model must still select valid rules.
    model = %Test{
      script: [
        response([final("No hay un objetivo registrado para ese ataque.")]),
        response([final()])
      ]
    }

    assert {:ok, fresh} = Game.restart(game.id, opts(model))
    start_supervised!({Dragonex.Test.GameFixture, fresh})
    assert :ok == Game.resume(fresh)
    finish(fresh)
    assert :ok == Game.pause(fresh)
    assert Games.completed_narration(game.id, "Thane", turn) == @declaration

    assert Enum.count(Games.list_events(game.id), &(&1.type == :action and &1.actor == "Thane")) ==
             1

    assert Game.world(fresh).characters == before.characters
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 0
  end

  test "corrective closure reuses a paid human attack, including RNG and public source", %{
    game: game,
    world: before
  } do
    {:ok, battle} = World.add_character(Monsters.goblin(name: "g1")).(before)
    battle = put_in(battle.characters["g1"].hp, 1)
    {:ok, battle} = World.begin_combat(["Thane", "g1"]).(battle)
    {:ok, _} = Games.save_state(game.id, battle, "Thane", battle.round, :paused)
    counter = start_supervised!({Agent, fn -> [] end})

    roller = fn sides ->
      Agent.update(counter, &[sides | &1])
      if sides == 20, do: 15, else: 1
    end

    attack =
      call("make_attack", %{"attacker" => "Thane", "target" => "g1", "weapon" => "longsword"})

    script = [
      response([attack]),
      response([final("«No dejaré supervivientes», grito."), attack]),
      response([attack]),
      response([final("Acción resuelta.")]),
      response([final("El goblin yace inmóvil en el patio.")])
    ]

    pid = boot(game, %Test{script: script}, roller: roller)
    assert :ok == Game.resume(pid)
    finish(pid)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @declaration)
    finish(pid)
    assert :ok == Game.pause(pid)
    assert Agent.get(counter, &Enum.reverse/1) == [20, 8]
    assert Game.world(pid).characters["g1"].hp == 0
    assert Game.world(pid).characters["Thane"] == before.characters["Thane"]
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2

    assert [
             %{
               payload: %{
                 "text" => @declaration,
                 "kind" => "human_declaration",
                 "complete" => true
               }
             }
           ] = Enum.filter(narration(game), &(&1.actor == "Thane"))

    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)

    refute inspect(History.import_events(Games.list_events(game.id)) |> ModelMessages.project()) =~
             "No dejaré supervivientes"
  end
end
