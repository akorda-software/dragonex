defmodule Dragonex.GameInventoryRoundTripTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games, Repo, Tools}
  alias Dragonex.Game.ToolReplay
  alias Dragonex.Rules.InventoryRoundTrip
  alias ExAgent.Models.Test

  @declaration "Ada me presta el sello un momento; lo miro y se lo devuelvo enseguida."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp args(extra) do
    Map.merge(
      %{
        "who" => "Thane",
        "item" => "sello",
        "quantity" => 1,
        "counterparty" => "Ada",
        "direction" => "borrow_return"
      },
      extra
    )
  end

  defp episode(extra \\ %{}), do: tool_calls([call("record_item_round_trip", args(extra))])
  defp closure, do: narration("Ada recupera su sello después de mostrarlo.")

  defp no_transfer,
    do:
      tool_calls([
        call("confirm_no_inventory_transfer", %{
          "who" => "Thane",
          "outcome" => "declined",
          "reason" => "[DM]: Ada no entrega el sello."
        })
      ])

  defp opts(script) do
    [
      model: %Test{script: script},
      scene_model: %Test{
        script: [tool_calls([call("final_result", %{"scene" => "El sello sigue con Ada."})])]
      }
    ]
  end

  defp boot(script) do
    hero = %{Archetypes.wizard(name: "Thane") | inventory: []}
    {:ok, game} = Games.create_game(title: "El sello vuelve a Ada", roster: [{hero, :human}])
    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, opts([narration("Pido ver el sello.") | script]))
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    %{game: game, pid: pid, before: before}
  end

  defp declare(context),
    do: assert({:ok, :resolving} = Game.declare(context.pid, "Thane", @declaration))

  defp finish(context) do
    assert :ok =
             Game.await(context.pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)

    assert :ok = Game.pause(context.pid)
    world = Game.world(context.pid)
    assert world.characters == context.before.characters
    assert Games.load_world(Games.get_game(context.game.id)) == world
    world
  end

  defp events(id, kind),
    do: Enum.filter(Games.list_events(id), &(&1.type == :system and &1.payload["kind"] == kind))

  defp assert_episode(context) do
    assert [received, returned] = events(context.game.id, "inventory_movement")
    assert received.payload["leg_index"] == 1
    assert returned.payload["leg_index"] == 2
    assert received.payload["movement_group"] == returned.payload["movement_group"]
    assert is_binary(received.payload["movement_group"])
    assert {received.payload["balance_before"], received.payload["balance_after"]} == {0, 1}
    assert {returned.payload["balance_before"], returned.payload["balance_after"]} == {1, 0}
    assert {received.payload["source"], received.payload["recipient"]} == {"Ada", "Thane"}
    assert {returned.payload["source"], returned.payload["recipient"]} == {"Thane", "Ada"}
    assert received.payload["turn_id"] == returned.payload["turn_id"]
    assert events(context.game.id, "inventory_no_transfer") == []
  end

  test "a repeated successful call in one beat reuses the episode even if attribution changes" do
    owner = self()

    context =
      boot([
        episode(),
        episode(%{"counterparty" => "Otra persona", "item" => " SELLO "}),
        fn messages, _ ->
          send(
            owner,
            {:episode_replayed,
             inspect(messages, limit: :infinity) =~ "Resultado ya aplicado antes del fallo"}
          )

          closure()
        end
      ])

    try do
      declare(context)
      finish(context)
      assert_episode(context)
      assert_receive {:episode_replayed, true}
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "retry after a truncated narration retains two legs without repeating the episode" do
    context =
      boot([
        episode(),
        ExAgent.Message.new_response([], finish_reason: :length),
        episode(),
        closure()
      ])

    try do
      declare(context)
      finish(context)
      assert_episode(context)
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "restart preserves the captured request, paid episode and exact inventory" do
    owner = self()

    context =
      boot([
        episode(),
        fn _, _ ->
          send(owner, {:episode_paid, self()})
          receive do: (:complete -> closure())
        end
      ])

    try do
      declare(context)
      assert_receive {:episode_paid, run}, 2_000
      assert :ok = Game.pause(context.pid)
      saved = Game.world(context.pid)
      assert saved.characters == context.before.characters

      assert %{"actor" => "Thane", "kind" => "round_trip", "seq" => seq} =
               saved.actor_checkpoint["inventory_resolution"]

      assert is_integer(seq)
      loaded = saved |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()

      assert %{inventory_resolution: %{actor: "Thane", kind: :round_trip, seq: ^seq}} =
               ToolReplay.restore(loaded, "dm")

      legacy = update_in(loaded.actor_checkpoint, &Map.delete(&1, "inventory_resolution"))
      refute Map.has_key?(ToolReplay.restore(legacy, "dm"), :inventory_resolution)
      explicit_nil = put_in(loaded.actor_checkpoint["inventory_resolution"], nil)
      assert %{inventory_resolution: nil} = ToolReplay.restore(explicit_nil, "dm")
      monitor = Process.monitor(run)
      {:ok, fresh} = Game.restart(context.game.id, opts([episode(), closure()]))
      assert_receive {:DOWN, ^monitor, :process, ^run, _}, 1_000
      assert Game.world(fresh) == saved
      assert :ok = Game.resume(fresh)
      finish(%{context | pid: fresh})
      assert_episode(context)
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "a resolved episode rejects changed quantity/item and contradictory no-transfer" do
    context =
      boot([
        episode(),
        episode(%{"quantity" => 2}),
        episode(%{"item" => "medalla"}),
        no_transfer(),
        closure()
      ])

    try do
      declare(context)
      finish(context)
      assert_episode(context)
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "a typed refusal is durable, scrubbed, exclusive and replayed once" do
    context = boot([no_transfer(), no_transfer(), episode(), narration("Ada conserva el sello.")])

    try do
      declare(context)
      finish(context)
      assert events(context.game.id, "inventory_movement") == []
      assert [refusal] = events(context.game.id, "inventory_no_transfer")
      assert refusal.payload["stock_owner"] == "Thane"
      assert refusal.payload["outcome"] == "declined"
      assert refusal.payload["reason"] == "Ada no entrega el sello."
      refute refusal.payload["note"] =~ "[DM]"
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end

  test "failure of the second SQL leg rolls back both events, World and paid receipt" do
    context = boot([episode(), closure()])
    owner = self()
    raw = Enum.find(Tools.tools(), &(&1.name == "record_item_round_trip"))
    schema = Enum.find(Tools.agent_tools(), &(&1.name == raw.name)).parameters_json_schema

    prepared =
      ToolReplay.wrap(%{
        raw
        | parameters_json_schema: schema,
          call: fn ctx, input ->
            send(owner, {:episode_prepared, self()})

            receive do
              :commit ->
                result = raw.call.(ctx, input)
                send(owner, {:episode_commit, result, ctx})
                receive do: (:reply -> result)
            end
          end
      })

    :sys.replace_state(:sys.get_state(context.pid).dm, fn server ->
      tools = Enum.map(server.agent.tools, &if(&1.name == raw.name, do: prepared, else: &1))
      %{server | agent: %{server.agent | tools: tools}}
    end)

    try do
      declare(context)
      assert_receive {:episode_prepared, run}, 2_000
      assert :ok = Game.pause(context.pid)
      before = Game.world(context.pid)
      Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(context.game.id))

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE game_events ADD CONSTRAINT reject_second_inventory_leg CHECK (game_id <> #{context.game.id} OR payload->>'leg_index' IS DISTINCT FROM '2')",
        []
      )

      send(run, :commit)
      assert_receive {:episode_commit, {:error, :persistence_failed}, ctx}, 2_000
      assert Game.world(context.pid) == before
      assert Games.load_world(Games.get_game(context.game.id)) == before
      assert events(context.game.id, "inventory_movement") == []
      refute_receive {:game_updated, _}, 20

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE game_events DROP CONSTRAINT reject_second_inventory_leg",
        []
      )

      change = fn world ->
        InventoryRoundTrip.apply(world, "Thane", "sello", 1, "Ada", "borrow_return")
      end

      assert {:ok, paid} = Game.commit_rule_change(context.pid, ctx.deps, change)
      assert paid.characters == before.characters
      assert [%{"name" => "record_item_round_trip"}] = paid.actor_checkpoint["tools"]
      assert_episode(context)
      assert {:error, _} = Game.commit_rule_change(context.pid, ctx.deps, change)
      assert_episode(context)
      assert Game.world(context.pid) == paid
    after
      Dragonex.Game.Supervisor.stop_game(context.game.id)
    end
  end
end
