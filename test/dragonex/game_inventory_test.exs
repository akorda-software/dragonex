defmodule Dragonex.GameInventoryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, Item, World}
  alias ExAgent.Models.Test

  @question "Le pregunto al zagal: «¿Es tuyo este botón?» Lo recojo y lo guardo en la bolsa."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(script, stock \\ 0) do
    hero = %{Archetypes.wizard(name: "Thane") | inventory: []}

    {:ok, game} =
      Games.create_game(
        title: "Inventario confirmado",
        scene: "El cruce del molino.",
        roster: [{hero, :human}]
      )

    before = Games.load_world(game)

    before =
      if stock == 0,
        do: before,
        else: elem(World.grant_item(hero.name, "botón de latón", stock).(before), 1)

    before = %{before | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, hero.name, before.round, :paused)
    parent = self()

    unexpected = fn _, _ ->
      send(parent, :inventory_auxiliary_called)
      "No debe llamarse."
    end

    recorder = %Test{script: [tool_calls([call("final_result", %{"scene" => before.scene})])]}

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: script},
        turnmaster_model: %Test{script: [unexpected]},
        scene_model: recorder
      )

    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.current == hero.name and &1.status == :waiting))
    {game, pid, before}
  end

  defp wait(pid) do
    assert :ok = Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok = Game.pause(pid)
  end

  test "two actual beats add then remove gear and the next DM reads the current stock" do
    parent = self()

    give = fn messages, _ ->
      send(
        parent,
        {:inventory_before,
         String.contains?(inspect(messages, limit: :infinity), "Inventario: vacío")}
      )

      tool_calls([
        call("grant_item", %{
          "who" => "Thane",
          "item" => "botón de latón",
          "quantity" => 2,
          "source" => "  Ada  "
        })
      ])
    end

    take = fn messages, _ ->
      send(
        parent,
        {:inventory_after,
         String.contains?(inspect(messages, limit: :infinity), "Inventario: botón de latón ×2")}
      )

      tool_calls([
        call("remove_item", %{
          "who" => "Thane",
          "item" => "botón de latón",
          "quantity" => 1,
          "recipient" => "Elia"
        })
      ])
    end

    {game, pid, before} =
      boot([
        narration("Recojo los botones."),
        give,
        narration("El zagal responde."),
        narration("Entrego un botón."),
        take,
        narration("El zagal lo recibe.")
      ])

    try do
      assert {:ok, :resolving} = Game.declare(pid, "Thane", @question)
      wait(pid)
      assert_receive {:inventory_before, true}
      assert [%Item{qty: 2}] = Game.world(pid).characters["Thane"].inventory
      assert :ok = Game.resume(pid)
      assert :ok = Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))

      assert {:ok, :resolving} =
               Game.declare(
                 pid,
                 "Thane",
                 "Le pregunto al zagal: ¿Quieres un botón? Le entrego uno de los dos."
               )

      wait(pid)
      assert_receive {:inventory_after, true}
      world = Game.world(pid)
      assert [%Item{qty: 1}] = world.characters["Thane"].inventory
      assert %{before | characters: world.characters} == world

      assert %{before.characters["Thane"] | inventory: world.characters["Thane"].inventory} ==
               world.characters["Thane"]

      assert Games.load_world(Games.get_game(game.id)) == world
      assert [received, given] = movements(game.id)
      assert received.payload["source"] == "Ada"
      assert received.payload["recipient"] == "Thane"
      assert received.payload["quantity"] == 2
      assert received.payload["balance_before"] == 0
      assert received.payload["balance_after"] == 2
      assert given.payload["source"] == "Thane"
      assert given.payload["recipient"] == "Elia"
      assert given.payload["quantity"] == 1
      assert given.payload["balance_before"] == 2
      assert given.payload["balance_after"] == 1
      assert given.payload["stock_owner"] == "Thane"
      assert given.payload["item_key"] == "botón de latón"
      assert given.payload["counterparty_declared"]
      assert received.payload["turn_id"] != given.payload["turn_id"]
      assert map_size(world.characters) == 1
      history = Dragonex.History.from_events(Games.list_events(game.id), "dm")
      assert inspect(history, limit: :infinity) =~ "a Elia; saldo 2 → 1"
      refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
      refute_received :inventory_auxiliary_called
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "an NPC request stays pending until the DM confirms the handover through the tool" do
    parent = self()

    give = fn messages, _ ->
      context = inspect(messages, limit: :infinity)

      send(
        parent,
        {:pending_handover, String.contains?(context, "Inventario: vacío"),
         String.contains?(
           context,
           "Última declaración pendiente de consecuencias del mundo — Thane:"
         )}
      )

      tool_calls([
        call("grant_item", %{"who" => "Thane", "item" => "botón de latón", "quantity" => 1})
      ])
    end

    {game, pid, before} =
      boot([
        narration("Espero con la palma abierta."),
        give,
        narration("El zagal pone el botón en tu mano.")
      ])

    try do
      assert Game.world(pid) == before

      assert {:ok, :resolving} =
               Game.declare(
                 pid,
                 "Thane",
                 "Le pregunto al zagal: «¿Me devuelves el botón de latón?» Extiendo la palma y espero su respuesta."
               )

      wait(pid)
      assert_receive {:pending_handover, true, true}
      world = Game.world(pid)
      assert [%Item{qty: 1}] = world.characters["Thane"].inventory
      assert %{before | characters: world.characters} == world
      assert Games.load_world(Games.get_game(game.id)) == world
      refute_received :inventory_auxiliary_called
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  for operation <- ["grant_item", "remove_item"] do
    test "restart preserves committed #{operation} with equivalent spelling and a single effect" do
      operation = unquote(operation)
      parent = self()
      field = if operation == "grant_item", do: "source", else: "recipient"

      first =
        tool_calls([
          call(operation, %{
            "who" => "Thane",
            "item" => "botón de latón",
            "quantity" => 1,
            field => "Ada"
          })
        ])

      blocked = fn _, _ ->
        send(parent, {:inventory_committed, self()})
        receive do: (:finish -> narration("El zagal confirma."))
      end

      {game, pid, before} =
        boot(
          [narration("Muestro el botón al zagal."), first, blocked],
          if(operation == "grant_item", do: 0, else: 2)
        )

      try do
        assert {:ok, :resolving} = Game.declare(pid, "Thane", @question)
        assert_receive {:inventory_committed, run}, 2_000
        assert :ok = Game.pause(pid)
        saved = Game.world(pid)
        assert [%Item{qty: 1}] = saved.characters["Thane"].inventory
        assert saved.actor_checkpoint != nil
        assert Games.load_world(Games.get_game(game.id)) == saved
        assert [movement] = movements(game.id)
        assert movement.payload["turn_id"] == saved.actor_checkpoint["turn_id"]
        assert movement.payload[field] == "Ada"
        monitor = Process.monitor(run)

        retry_args = %{
          "who" => "Thane",
          "item" => " BOTO\u0301N   DE LATO\u0301N ",
          "quantity" => 1
        }

        retry_args =
          if operation == "remove_item",
            do: Map.put(retry_args, "recipient", nil),
            else: retry_args

        retry = tool_calls([call(operation, retry_args)])

        final = fn messages, _ ->
          send(
            parent,
            {:inventory_replayed,
             String.contains?(
               inspect(messages, limit: :infinity),
               "Resultado ya aplicado antes del fallo"
             )}
          )

          narration("El zagal confirma.")
        end

        recorder = %Test{script: [tool_calls([call("final_result", %{"scene" => before.scene})])]}

        {:ok, fresh} =
          Game.restart(game.id, model: %Test{script: [retry, final]}, scene_model: recorder)

        assert fresh != pid
        assert_receive {:DOWN, ^monitor, :process, ^run, _}, 1_000
        assert Game.world(fresh) == saved
        assert :ok = Game.resume(fresh)
        wait(fresh)
        assert_receive {:inventory_replayed, true}
        world = Game.world(fresh)
        assert [%Item{qty: 1}] = world.characters["Thane"].inventory
        assert %{before | characters: world.characters} == world
        assert Games.load_world(Games.get_game(game.id)) == world
        events = Games.list_events(game.id)
        assert movements(game.id) == [movement]

        assert Enum.count(
                 events,
                 &(&1.type == :narration and &1.actor == "Thane" and &1.payload["complete"])
               ) == 1

        assert Enum.count(
                 events,
                 &(&1.type == :narration and &1.actor == "dm" and &1.payload["complete"])
               ) == 1

        refute Enum.any?(events, &(&1.type == :dice))
        refute_received :inventory_auxiliary_called
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end

  for operation <- ["grant_item", "remove_item"] do
    test "retry of #{operation} cannot repeat stock or rewrite the original counterparty" do
      operation = unquote(operation)
      field = if operation == "grant_item", do: "source", else: "recipient"
      args = %{"who" => "Thane", "item" => "botón de latón", "quantity" => 1}
      parent = self()

      replayed = fn messages, _ ->
        send(
          parent,
          {:inventory_replay,
           inspect(messages, limit: :infinity) =~ "Resultado ya aplicado antes del fallo"}
        )

        narration("La entrega queda confirmada.")
      end

      {game, pid, _before} =
        boot(
          [
            narration("Muestro el botón al zagal."),
            tool_calls([call(operation, Map.put(args, field, "Ada"))]),
            ExAgent.Message.new_response([], finish_reason: :length),
            tool_calls([call(operation, Map.put(args, field, "Otra persona"))]),
            replayed
          ],
          if(operation == "grant_item", do: 0, else: 2)
        )

      try do
        assert {:ok, :resolving} = Game.declare(pid, "Thane", @question)
        wait(pid)
        assert_receive {:inventory_replay, true}
        assert [%Item{qty: 1}] = Game.world(pid).characters["Thane"].inventory
        assert [movement] = movements(game.id)
        assert movement.payload[field] == "Ada"
        assert movement.payload["quantity"] == 1
        assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
      after
        Dragonex.Game.Supervisor.stop_game(game.id)
      end
    end
  end

  defp movements(game_id),
    do:
      Enum.filter(
        Games.list_events(game_id),
        &(&1.type == :system and &1.payload["kind"] == "inventory_movement")
      )
end
