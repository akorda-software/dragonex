defmodule Dragonex.CredentialRevocationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness

  alias Dragonex.{Accounts, Archetypes, Character, Game, GameAI, Games}
  alias Dragonex.GameAI.OwnKeyModel
  alias ExAgent.{Model, ModelRequestParameters, Server}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    user = user()
    :ok = Accounts.put_api_key(user, "openai", "synthetic-key-one-1234")
    %{user: user}
  end

  test "withdrawal rotates only matching live tables and preserves their Session and world", %{
    user: user
  } do
    {game, pid} = table(user, guarded(user, %Test{}))
    {:ok, _} = Game.ensure_started(game.id)
    :ok = Game.enable_auto_play(pid, "Thane")
    before = :sys.get_state(pid)
    world = Game.world(pid)
    events = Games.list_events(game.id)
    other = user()
    :ok = Accounts.put_api_key(other, "openai", "synthetic-other-key-5678")
    {other_game, other_pid} = table(other, guarded(other, %Test{}))
    other_before = :sys.get_state(other_pid)

    assert :ok = Accounts.delete_api_key(user, "openai")
    after_state = :sys.get_state(pid)
    assert Game.Supervisor.whereis(game.id) == pid
    assert after_state.session == before.session
    assert after_state.status == :paused
    assert %Test{} = after_state.model
    refute Process.alive?(before.dm)
    refute Process.alive?(before.turnmaster)
    assert Map.keys(after_state.pc_agents) == Map.keys(before.pc_agents)
    refute Process.alive?(before.pc_agents["Thane"])
    assert Process.alive?(after_state.pc_agents["Thane"])
    assert Game.world(pid) == world
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Games.get_game(game.id).ai == %{"source" => "house"}
    assert Enum.take(Games.list_events(game.id), length(events)) == events
    assert List.last(Games.list_events(game.id)).payload["kind"] == "api_key_changed"
    assert :sys.get_state(other_pid).dm == other_before.dm
    assert Games.get_game(other_game.id).ai["source"] == "own"
  end

  test "a same-second replacement changes the generation and rotates to the new own key", %{
    user: user
  } do
    {game, pid} = table(user, guarded(user, %Test{}))
    old = :sys.get_state(pid).model
    assert :ok = Accounts.put_api_key(user, "openai", "synthetic-key-two-2345")
    current = :sys.get_state(pid).model
    assert %OwnKeyModel{} = current
    assert current.version != old.version
    assert current.version == Accounts.api_key_version(user.id, "openai")
    assert Game.status(pid) == :paused
    assert Games.get_game(game.id).ai["source"] == "own"
    assert {:error, :credential_revoked} = Model.request(old, [], nil, %ModelRequestParameters{})
    refute inspect(current) =~ "synthetic"
  end

  test "unloaded tables use the house on reopening without changing their saved state", %{
    user: user
  } do
    {:ok, game} =
      Games.create_game(user_id: user.id, roster: [{Archetypes.fighter(), :human}], open_slots: 1)

    :ok = Games.set_ai(game.id, own())
    before = Games.get_game(game.id)
    assert Game.Supervisor.whereis(game.id) == nil
    assert :ok = Accounts.delete_api_key(user, "openai")
    updated = Games.get_game(game.id)
    assert updated.ai == %{"source" => "house"}
    assert updated.world == before.world
    assert updated.status == before.status
    assert Game.Supervisor.whereis(game.id) == nil
    {:ok, pid} = Game.ensure_started(game.id)
    assert Game.status(pid) == before.status
    assert %Test{} = :sys.get_state(pid).model
  end

  test "an unloaded running table pauses before it can reopen with a different payer", %{
    user: user
  } do
    {:ok, game} = Games.create_game(user_id: user.id, roster: [{Archetypes.fighter(), :human}])
    :ok = Games.set_ai(game.id, own())
    {:ok, _} = Games.set_status(game.id, :running)
    events = Games.list_events(game.id)
    assert :ok = Accounts.delete_api_key(user, "openai")
    assert Games.get_game(game.id).status == :paused
    {:ok, pid} = Game.ensure_started(game.id)
    assert Game.status(pid) == :paused
    assert Games.list_events(game.id) == events
  end

  test "an admitted standalone request is cancelled and its retired model cannot start another",
       %{user: user} do
    parent = self()

    model =
      guarded(user, %Test{
        script: [
          fn _, _ ->
            send(parent, {:request_started, self()})
            receive do: (:finish -> "OK")
          end
        ]
      })

    {:ok, task} =
      Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
        send(parent, {:finished, Model.request(model, [], nil, %ModelRequestParameters{})})
      end)

    ref = Process.monitor(task)
    assert_receive {:request_started, ^task}, 2_000
    assert :ok = Accounts.delete_api_key(user, "openai")
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    refute_received {:finished, _}

    assert {:error, :credential_revoked} =
             Model.request(model, [], nil, %ModelRequestParameters{})

    assert_request_unregistered(user.id)
  end

  test "stream admission is lazy and halted streams release their registration", %{user: user} do
    model = guarded(user, %Test{label: "hello world"})
    stream = Model.request_stream(model, [], nil, %ModelRequestParameters{})
    assert Enum.take(stream, 1) != []
    assert Registry.lookup(Dragonex.GameAI.RequestRegistry, {user.id, "openai"}) == []
    stale = Model.request_stream(model, [], nil, %ModelRequestParameters{})
    assert :ok = Accounts.delete_api_key(user, "openai")
    assert Enum.to_list(stale) == [{:error, :credential_revoked}]
  end

  test "withdrawal cancels an enumerating stream and denies later stream admissions", %{
    user: user
  } do
    parent = self()

    model =
      guarded(user, %Test{
        script: [
          fn _, _ ->
            send(parent, {:stream_started, self()})
            receive do: (:finish -> "late response")
          end
        ]
      })

    {:ok, task} =
      Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
        result = Model.request_stream(model, [], nil, %ModelRequestParameters{}) |> Enum.to_list()
        send(parent, {:stream_finished, result})
      end)

    ref = Process.monitor(task)
    assert_receive {:stream_started, ^task}, 2_000
    assert :ok = Accounts.delete_api_key(user, "openai")
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    refute_received {:stream_finished, _}

    assert Model.request_stream(model, [], nil, %ModelRequestParameters{}) |> Enum.to_list() ==
             [{:error, :credential_revoked}]

    assert_request_unregistered(user.id)
  end

  test "a retired probe cannot apply its cached model after the key disappears", %{user: user} do
    {game, pid} = table(user, guarded(user, %Test{}))

    {:ok, cached} =
      GameAI.build(%{source: :own, provider: "openai", model: "gpt-test", metadata: nil}, user.id)

    assert :ok = Accounts.delete_api_key(user, "openai")
    assert {:error, :missing_key} = Game.restart(game.id, cached ++ [ai: own()])
    assert Game.Supervisor.whereis(game.id) == pid
    assert Games.get_game(game.id).ai == %{"source" => "house"}
  end

  test "removing a key after a paid spell retains its checkpoint and replay spends once", %{
    user: user
  } do
    caster =
      Character.new(
        name: "Mara",
        class: "wizard",
        hp: 8,
        max_hp: 8,
        int: 16,
        spells: [
          Dragonex.Heroes.Spells.to_character_spell(
            Dragonex.Heroes.Spells.get("magic missile"),
            :int
          )
        ]
      )

    enemy = Character.new(name: "Goblin", side: "enemy", hp: 20, max_hp: 20)
    parent = self()

    cast =
      tool_calls([
        call("cast_spell", %{"caster" => "Mara", "spell" => "magic missile", "target" => "Goblin"})
      ])

    model =
      guarded(user, %Test{
        script: [
          cast,
          fn _, _ ->
            send(parent, {:paid, self()})
            receive do: (:finish -> narration("Invoco los proyectiles."))
          end
        ]
      })

    {game, pid} =
      table(user, model,
        roster: [{caster, :ai}, {Archetypes.fighter(), :human}, {enemy, :ai}],
        current: "Mara"
      )

    assert :ok = Game.resume(pid)
    assert_receive {:paid, request}, 2_000
    ref = Process.monitor(request)
    paid = Game.world(pid)
    assert paid.spell_slots["Mara"][1] == 1
    assert paid.characters["Goblin"].hp == 14

    assert :ok = Accounts.delete_api_key(user, "openai")
    assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
    assert Game.status(pid) == :paused
    retained = Game.world(pid)
    assert Map.delete(retained, :actor_checkpoint) == Map.delete(paid, :actor_checkpoint)
    assert retained.actor_checkpoint["turn_id"] == paid.actor_checkpoint["turn_id"]
    refute Enum.any?(Games.list_events(game.id), &(&1.payload["kind"] == "turn_failed"))

    state = :sys.get_state(pid)

    :ok =
      Server.set_model(state.pc_agents["Mara"], %Test{
        script: [cast, narration("Invoco los proyectiles.")]
      })

    :ok =
      Server.set_model(state.dm, %Dragonex.Test.Narrator{text: "Thane, ¿qué quieres observar?"})

    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert Game.world(pid).spell_slots["Mara"][1] == 1
    assert Game.world(pid).characters["Goblin"].hp == 14
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
    assert Enum.count(Games.list_events(game.id), &(&1.type == :turn and &1.actor == "Mara")) == 1
  end

  test "rotation during a TurnMaster request keeps its phase instead of repeating the prior actor",
       %{user: user} do
    parent = self()

    tm =
      guarded(user, %Test{
        script: [
          fn _, _ ->
            send(parent, {:tm_request, self()})
            receive do: (:finish -> "no decision")
          end
        ]
      })

    {game, pid} = table(user, guarded(user, %Test{}), turnmaster_model: tm)
    :sys.replace_state(pid, &%{&1 | loop_phase: :turnmaster, last_actor: "Thane"})
    assert :ok = Game.resume(pid)
    assert_receive {:tm_request, request}, 2_000
    ref = Process.monitor(request)
    before = Game.world(pid)
    assert :ok = Accounts.delete_api_key(user, "openai")
    assert_receive {:DOWN, ^ref, :process, ^request, _}, 1_000
    assert :sys.get_state(pid).loop_phase == :turnmaster
    assert Game.world(pid) == before
    assert Games.get_game(game.id).ai == %{"source" => "house"}
  end

  defp table(user, model, opts \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "Credential transition",
        user_id: user.id,
        roster:
          Keyword.get(opts, :roster, [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :ai}])
      )

    {:ok, _} =
      Games.save_state(
        game.id,
        Games.load_world(game),
        Keyword.get(opts, :current, "dm"),
        1,
        :paused
      )

    :ok = Games.set_ai(game.id, own())

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: model,
        summarizer: %Test{},
        turnmaster_model: Keyword.get(opts, :turnmaster_model, %Test{}),
        scene_model: %Test{},
        roller: fn _ -> 1 end
      )

    {game, pid}
  end

  # DOWN confirms cancellation; Registry's partition removes the dead process's
  # entries independently. Wait for that postcondition, not an assumed delay.
  defp assert_request_unregistered(user_id),
    do: await_request_unregistered(user_id, System.monotonic_time(:millisecond) + 1_000)

  defp await_request_unregistered(user_id, deadline) do
    case Registry.lookup(Dragonex.GameAI.RequestRegistry, {user_id, "openai"}) do
      [] ->
        :ok

      _entries ->
        assert System.monotonic_time(:millisecond) < deadline,
               "Registry did not remove the cancelled request registration"

        receive do
        after
          1 -> await_request_unregistered(user_id, deadline)
        end
    end
  end

  defp own,
    do: %{"source" => "own", "provider" => "openai", "model" => "gpt-test", "metadata" => nil}

  defp guarded(user, model),
    do: %OwnKeyModel{
      inner: model,
      user_id: user.id,
      provider: "openai",
      version: Accounts.api_key_version(user.id, "openai")
    }

  defp user do
    {:ok, user} =
      Accounts.register(%{
        email: "revoke-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Owner"
      })

    user
  end
end
