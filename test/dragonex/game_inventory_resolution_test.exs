defmodule Dragonex.GameInventoryResolutionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Game, Games, Item, World}
  alias Dragonex.Game.InventoryResolution
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  @pickup "Subo al altillo, abro el arcón azul y tomo el libro de cuentas."
  @answer "El libro pesa más de lo que parece; Mara lo guarda bajo el brazo."
  @unrecorded "Mara se lleva el libro, pero el inventario no se entera."
  @loan "Ada, ¿me prestas el sello un instante para ver mejor la efigie? Cuando ella me lo presta, lo miro y se lo devuelvo inmediatamente a Ada. El encargo sigue terminado."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(script) do
    {:ok, game} =
      Games.create_game(
        title: "El libro de cuentas",
        scene: "El altillo del molino.",
        roster: [{%{Archetypes.wizard(name: "Mara") | inventory: []}, :human}]
      )

    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, "Mara", before.round, :paused)
    # The routine scene review after an exploration beat keeps the scene.
    recorder = fn _, _ -> tool_calls([call("final_result", %{"scene" => before.scene})]) end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{script: script},
        scene_model: %Test{script: [recorder]},
        turnmaster_model: %Test{
          script: [tool_calls([call("give_turn_to", %{"participant" => "Mara"})]), "listo"]
        }
      )

    on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    {game, pid, before}
  end

  defp finish(game, pid) do
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    world = Game.world(pid)
    assert Codec.decode(Codec.encode(world)) == world
    assert Games.load_world(Games.get_game(game.id)) == world
    events = Games.list_events(game.id)

    assert Enum.count(
             events,
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["complete"] == true)
           ) == 1

    refute Enum.any?(events, &String.contains?(&1.payload["text"] || "", @unrecorded))
    world
  end

  # The first scripted reply resolves Mara's own beat (her voice stays the
  # literal declaration); the DM beat starts with an unrecorded closure.
  test "a declared pickup withholds the closure until the DM grants the item" do
    owner = self()

    required = fn messages, params ->
      context = messages |> ModelMessages.project() |> Enum.map_join("\n", &(&1["content"] || ""))

      send(
        owner,
        {:inventory_required,
         %{
           guide: context =~ "RECOGIDA O ENTREGA PENDIENTE",
           feedback: context =~ "Registra primero el inventario"
         }, params.allow_text_output}
      )

      tool_calls([
        call("grant_item", %{"who" => "Mara", "item" => "libro de cuentas", "quantity" => 1})
      ])
    end

    final = fn _, params ->
      send(owner, {:inventory_ready, params.allow_text_output})
      narration(@answer)
    end

    {game, pid, _before} = boot([narration(@pickup), narration(@unrecorded), required, final])
    assert {:ok, :resolving} == Game.declare(pid, "Mara", @pickup)
    world = finish(game, pid)
    assert [%Item{name: "libro de cuentas", qty: 1}] = world.characters["Mara"].inventory
    assert_receive {:inventory_required, %{guide: true, feedback: true}, false}
    assert_receive {:inventory_ready, _}
  end

  test "confirm_inventory_unchanged settles a pickup that does not happen without touching stock" do
    confirm =
      tool_calls([
        call("confirm_inventory_unchanged", %{
          "who" => "Mara",
          "reason" => "el arcón está vacío"
        })
      ])

    {game, pid, before} =
      boot([narration(@pickup), narration(@unrecorded), confirm, narration(@answer)])

    assert {:ok, :resolving} == Game.declare(pid, "Mara", @pickup)
    world = finish(game, pid)
    assert world.characters["Mara"].inventory == []
    assert world.characters == before.characters
  end

  test "a declaration without pickup or handover closes with plain narration" do
    declaration = "Miro el arcón azul desde la escalera."
    {game, pid, before} = boot([narration(declaration), narration(@answer)])
    assert {:ok, :resolving} == Game.declare(pid, "Mara", declaration)
    world = finish(game, pid)
    assert world.characters == before.characters
  end

  test "an immediate loan needs its two committed movements despite unchanged final stock" do
    round_trip = round_trip()

    {game, pid, before} =
      boot([
        narration(@loan),
        narration(@unrecorded),
        round_trip,
        narration("Ada recupera el sello.")
      ])

    assert {:ok, :resolving} = Game.declare(pid, "Mara", @loan)
    world = finish(game, pid)
    assert world.characters == before.characters
    assert_round_trip(game.id)
  end

  test "an ambiguous no-change confirmation cannot settle the loan or pay a partial leg" do
    parent = self()

    rejected = fn messages, _ ->
      context = messages |> ModelMessages.project() |> inspect(limit: :infinity)
      send(parent, {:partial_rejected, context =~ "record_item_round_trip"})
      round_trip()
    end

    for tool <- [
          call("confirm_inventory_unchanged", %{
            "who" => "Mara",
            "reason" => "lo devuelve inmediatamente y el saldo queda igual"
          }),
          call("grant_item", %{"who" => "Mara", "item" => "sello", "quantity" => 1}),
          call("remove_item", %{
            "who" => "Mara",
            "item" => "sello",
            "quantity" => 1,
            "recipient" => "Ada"
          })
        ] do
      {game, pid, before} =
        boot([
          narration(@loan),
          tool_calls([tool]),
          rejected,
          narration("Ada recupera el sello.")
        ])

      assert {:ok, :resolving} = Game.declare(pid, "Mara", @loan)
      world = finish(game, pid)
      assert world.characters == before.characters
      assert_round_trip(game.id)
      assert_receive {:partial_rejected, true}
    end
  end

  test "a typed refusal records no custody transfer and lets the DM close" do
    refusal =
      tool_calls([
        call("confirm_no_inventory_transfer", %{
          "who" => "Mara",
          "outcome" => "declined",
          "reason" => "Ada guarda el sello y no lo entrega."
        })
      ])

    {game, pid, before} =
      boot([narration(@loan), refusal, narration("Ada prefiere conservar el sello en su mano.")])

    assert {:ok, :resolving} = Game.declare(pid, "Mara", @loan)
    world = finish(game, pid)
    assert world.characters == before.characters
    assert movements(game.id) == []
  end

  for mode <- [:restart_before_payment, :restart_after_legacy_intermediate] do
    test "#{mode} keeps the unresolved loan and does not publish an unpaid closure" do
      {game, pid, before} =
        boot([narration(@loan), narration(@unrecorded), narration(@unrecorded)])

      assert {:ok, :resolving} = Game.declare(pid, "Mara", @loan)
      assert :ok = Game.await(pid, &(&1.status == :paused), 5_000)
      paused = Game.world(pid)
      assert paused.characters == before.characters
      assert movements(game.id) == []
      refute Enum.any?(Games.list_events(game.id), &(&1.payload["text"] == @unrecorded))

      if unquote(mode) == :restart_after_legacy_intermediate do
        # Historical intermediate narration is fixture data. Seed it only with
        # Game stopped; an active unresolved beat now rejects its publication.
        assert :ok = Dragonex.Game.Supervisor.stop_game(game.id)
        legacy = update_in(paused.actor_checkpoint, &Map.delete(&1, "inventory_resolution"))
        {:ok, _} = Games.save_state(game.id, legacy, "dm", legacy.round, :paused)

        {:ok, _} =
          Games.append_event(game.id, :narration, "dm", "all", %{
            text: "Ada levanta la mirada; aún no entrega el sello.",
            complete: false,
            turn_id: paused.actor_checkpoint["turn_id"]
          })
      else
        assert paused.actor_checkpoint["inventory_resolution"]["kind"] == "round_trip"
      end

      {:ok, reopened} =
        Game.restart(game.id,
          model: %Test{
            script: [narration(@unrecorded), round_trip(), narration("Ada recupera el sello.")]
          },
          scene_model: %Test{
            script: [
              fn _, _ -> tool_calls([call("final_result", %{"scene" => before.scene})]) end
            ]
          },
          turnmaster_model: %Test{
            script: [tool_calls([call("give_turn_to", %{"participant" => "Mara"})]), "listo"]
          }
        )

      refute reopened == pid
      assert :ok = Game.resume(reopened)
      world = finish(game, reopened)
      assert world.characters == before.characters
      assert_round_trip(game.id)
    end
  end

  test "a checkpoint without the new contract resumes its paid grant and completes the old return" do
    hero = %{
      Archetypes.wizard(name: "Mara")
      | inventory: [%Item{name: "piedra azul", qty: 2, kind: :gear}]
    }

    {:ok, game} = Games.create_game(title: "Préstamo anterior", roster: [{hero, :human}])
    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, paid} = World.grant_item("Mara", "sello", 1).(before)
    turn_id = "legacy-loan-before-captured-contract"
    grant_args = %{"who" => "Mara", "item" => "sello", "quantity" => 1}

    # Historical fixture, written before Game starts. The old checkpoint proves
    # its grant was paid but does not claim an ordered D265 loan or invent a
    # movement event that did not exist in that historical schema.
    paid = %{
      paid
      | actor_checkpoint: %{
          "actor" => "dm",
          "turn_id" => turn_id,
          "phase" => "exploration",
          "enemies_before" => [],
          "mini_turn" => false,
          "pending_narration" => true,
          "tools" => [
            %{"name" => "grant_item", "args" => grant_args, "values" => ["Mara recibe el sello."]}
          ]
        }
    }

    {:ok, _} = Games.append_event(game.id, :action, "Mara", "all", %{text: @loan})

    {:ok, _} =
      Games.append_event(game.id, :turn, "dm", "all", %{
        kind: "start",
        turn_id: turn_id,
        phase: "exploration",
        round: 1
      })

    {:ok, _} = Games.save_state(game.id, paid, "dm", 1, :paused)
    parent = self()

    return_item = fn messages, _ ->
      context = messages |> ModelMessages.project() |> inspect(limit: :infinity)
      send(parent, {:legacy_grant_replayed, context =~ "Resultado ya aplicado antes del fallo"})

      tool_calls([
        call("remove_item", %{
          "who" => "Mara",
          "item" => "sello",
          "quantity" => 1,
          "recipient" => "Ada"
        })
      ])
    end

    {:ok, pid} =
      Game.ensure_started(game.id,
        model: %Test{
          script: [
            tool_calls([call("grant_item", grant_args)]),
            return_item,
            narration("Ada vuelve a tener el sello.")
          ]
        },
        scene_model: %Test{
          script: [
            tool_calls([
              call("final_result", %{"scene" => "El sello está de nuevo en manos de Ada."})
            ])
          ]
        },
        turnmaster_model: %Test{
          script: [tool_calls([call("give_turn_to", %{"participant" => "Mara"})]), "listo"]
        },
        roller: fn _ -> flunk("A legacy inventory continuation has no dice") end
      )

    on_exit(fn -> Dragonex.Game.Supervisor.stop_game(game.id) end)
    assert :ok = Game.resume(pid)
    world = finish(game, pid)
    assert world.characters == before.characters
    assert_receive {:legacy_grant_replayed, true}
    assert [returned] = movements(game.id)
    assert returned.payload["tool"] == "remove_item"
    assert returned.payload["balance_before"] == 1
    assert returned.payload["balance_after"] == 0
    assert returned.payload["recipient"] == "Ada"

    refute Enum.any?(
             Games.list_events(game.id),
             &(&1.payload["tool"] == "record_item_round_trip")
           )
  end

  defp round_trip do
    tool_calls([
      call("record_item_round_trip", %{
        "who" => "Mara",
        "item" => "sello",
        "quantity" => 1,
        "direction" => "borrow_return",
        "counterparty" => "Ada"
      })
    ])
  end

  defp movements(game_id),
    do: Enum.filter(Games.list_events(game_id), &(&1.payload["kind"] == "inventory_movement"))

  defp assert_round_trip(game_id) do
    assert [received, returned] = movements(game_id)
    assert received.payload["stock_owner"] == "Mara"
    assert received.payload["source"] == "Ada"
    assert received.payload["recipient"] == "Mara"
    assert received.payload["balance_before"] == 0
    assert received.payload["balance_after"] == 1
    assert returned.payload["source"] == "Mara"
    assert returned.payload["recipient"] == "Ada"
    assert returned.payload["balance_before"] == 1
    assert returned.payload["balance_after"] == 0
    assert received.payload["item_key"] == returned.payload["item_key"]
    assert received.payload["quantity"] == returned.payload["quantity"]
  end

  describe "request/3" do
    defp action(text, seq),
      do: %{type: :action, actor: "Mara", seq: seq, visible_to: "all", payload: %{"text" => text}}

    defp dm(seq),
      do: %{type: :narration, actor: "dm", seq: seq, visible_to: "all", payload: %{"text" => "…"}}

    test "only the exploration DM beat answering the latest declaration is gated" do
      world = %World{phase: :exploration}
      events = [dm(1), action(@pickup, 2)]

      assert %{actor: "Mara", kind: :pickup, seq: 2} =
               InventoryResolution.request("dm", world, events)

      assert InventoryResolution.request("Mara", world, events) == nil
      assert InventoryResolution.request("dm", %World{phase: :combat}, events) == nil
      assert InventoryResolution.request("dm", world, events ++ [dm(3)]) == nil
      assert InventoryResolution.request("dm", world, [action("Miro el arcón.", 1)]) == nil

      private = %{action(@pickup, 4) | visible_to: "Mara"}
      assert InventoryResolution.request("dm", world, events ++ [dm(3), private]) == nil
    end

    test "instruction names the actor; no request adds nothing" do
      assert InventoryResolution.instruction(nil) == ""
      assert InventoryResolution.instruction(%{actor: "Mara"}) =~ "Mara"
    end
  end
end
