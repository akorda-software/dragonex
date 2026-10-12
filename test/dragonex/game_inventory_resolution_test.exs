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
