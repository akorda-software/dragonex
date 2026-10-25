defmodule Dragonex.GameInventoryCommitTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Repo, Tools, World}
  alias Dragonex.Game.ToolReplay
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "an SQL failure rolls back inventory, receipt and movement before publication" do
    {game, pid, before} = prepared_grant()
    assert :ok = Game.resume(pid)
    assert_receive {:inventory_prepared, tool}, 2_000
    assert :ok = Game.pause(pid)
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))
    assert movements(game.id) == []

    # Reject the movement insert after the candidate World/receipt was saved.
    # Sandbox rolls this temporary constraint back, including on assertion failure.
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE game_events ADD CONSTRAINT reject_test_inventory_movement CHECK (game_id <> #{game.id} OR payload->>'kind' IS DISTINCT FROM 'inventory_movement')",
      []
    )

    try do
      send(tool, :commit)
      assert_receive {:inventory_outcome, {:error, :persistence_failed}, ctx}, 2_000
      assert Process.alive?(pid)
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert movements(game.id) == []
      refute_receive {:game_updated, _}, 20

      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE game_events DROP CONSTRAINT reject_test_inventory_movement",
        []
      )

      assert {:ok, committed} =
               Game.commit_rule_change(pid, ctx.deps, World.grant_item("Mara", "sello", 1))

      assert [%{name: "sello", qty: 1}] = committed.characters["Mara"].inventory
      assert [%{"name" => "grant_item"}] = committed.actor_checkpoint["tools"]
      assert Games.load_world(Games.get_game(game.id)) == committed
      assert [movement] = movements(game.id)
      assert movement.payload["quantity"] == 1
      assert movement.payload["balance_before"] == 0
      assert movement.payload["balance_after"] == 1
      assert movement.payload["turn_id"] == committed.actor_checkpoint["turn_id"]
      assert_receive {:game_updated, game_id}, 500
      assert game_id == game.id
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(tool), do: Process.exit(tool, :kill)
    end
  end

  test "a rejected removal and an explicit no-change confirmation create no movement" do
    parent = self()

    reported = fn messages, _ ->
      send(
        parent,
        {:inventory_error, inspect(messages, limit: :infinity) =~ "no tiene ese objeto"}
      )

      narration("No tienes ese sello para entregarlo.")
    end

    {game, pid, before} =
      boot([
        tool_calls([
          call("remove_item", %{
            "who" => "Mara",
            "item" => "sello",
            "quantity" => 1,
            "recipient" => "Ada"
          })
        ]),
        tool_calls([
          call("confirm_inventory_unchanged", %{"who" => "Mara", "reason" => "No tiene el sello."})
        ]),
        reported
      ])

    try do
      assert :ok = Game.resume(pid)
      assert :ok = Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
      assert :ok = Game.pause(pid)
      assert_receive {:inventory_error, true}
      assert Game.world(pid).characters == before.characters
      assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
      assert movements(game.id) == []
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  defp boot(script) do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: []}
    {:ok, game} = Games.create_game(title: "Movimiento atómico", roster: [{hero, :human}])
    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, "dm", before.round, :paused)
    {:ok, pid} = Game.ensure_started(game.id, model: %Test{script: script})
    {game, pid, before}
  end

  defp prepared_grant do
    parent = self()

    {game, pid, before} =
      boot([
        tool_calls([call("grant_item", %{"who" => "Mara", "item" => "sello", "quantity" => 1})]),
        narration("El sello está guardado.")
      ])

    raw = Enum.find(Tools.tools(), &(&1.name == "grant_item"))
    schema = Enum.find(Tools.agent_tools(), &(&1.name == "grant_item")).parameters_json_schema

    prepared =
      ToolReplay.wrap(%{
        raw
        | parameters_json_schema: schema,
          call: fn ctx, args ->
            send(parent, {:inventory_prepared, self()})

            receive do
              :commit ->
                outcome = raw.call.(ctx, args)
                send(parent, {:inventory_outcome, outcome, ctx})
                receive do: (:reply -> outcome)
            end
          end
      })

    :sys.replace_state(:sys.get_state(pid).dm, fn server ->
      tools = Enum.map(server.agent.tools, &if(&1.name == "grant_item", do: prepared, else: &1))
      %{server | agent: %{server.agent | tools: tools}}
    end)

    {game, pid, before}
  end

  defp movements(game_id),
    do:
      Enum.filter(
        Games.list_events(game_id),
        &(&1.type == :system and &1.payload["kind"] == "inventory_movement")
      )
end
