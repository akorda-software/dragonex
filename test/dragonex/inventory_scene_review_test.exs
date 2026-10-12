defmodule Dragonex.InventorySceneReviewTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, World}
  alias Dragonex.Game.SceneRefresh
  alias Dragonex.Rules.Inventory
  alias ExAgent.Models.Test
  alias ExAgent.Session

  defp recorded_inventory do
    hero = %{Archetypes.wizard(name: "Mara") | inventory: []}
    before = World.new(scene: "El cruce del molino.", characters: %{hero.name => hero})
    {:ok, world} = World.grant_item(hero.name, "botón de latón", 1).(before)

    checkpoint = %{
      "actor" => "dm",
      "turn_id" => "inventory-scene",
      "phase" => "exploration",
      "enemies_before" => [],
      "mini_turn" => false,
      "inventory_scene_before" => %{
        "pending" => false,
        "fingerprint" => Inventory.scene_fingerprint(before)
      },
      "tools" => [
        %{
          "name" => "grant_item",
          "args" => %{"who" => hero.name, "item" => "botón de latón", "quantity" => 1},
          "values" => ["Objeto registrado."]
        }
      ]
    }

    %{world | actor_checkpoint: checkpoint}
  end

  defp unchanged(world) do
    model = %Test{script: [tool_calls([call("final_result", %{"scene" => world.scene})])]}
    SceneRefresh.propose(model, world, [])
  end

  test "inventory-only confirmation requires a durable unchanged-world proof" do
    world = recorded_inventory() |> Codec.encode() |> Codec.decode()
    assert {:unchanged_inventory, ^world, _} = unchanged(world)
    assert world.scene_refresh_pending
  end

  test "missing proof, prior pending review and changes beyond inventory reject unchanged confirmation" do
    world = recorded_inventory()
    original = world.actor_checkpoint
    without = %{world | actor_checkpoint: Map.delete(original, "inventory_scene_before")}
    pending = put_in(world.actor_checkpoint["inventory_scene_before"]["pending"], true)

    other_tool =
      update_in(
        world.actor_checkpoint["tools"],
        &(&1 ++ [%{"name" => "establish_fact", "args" => %{}, "values" => ["Dato guardado."]}])
      )

    for changed <- [
          without,
          pending,
          other_tool,
          %{world | elapsed_seconds: world.elapsed_seconds + 1},
          %{world | facts: ["Un puente está cerrado."]},
          put_in(world.characters["Mara"].hp, 1)
        ] do
      assert {:error, :unchanged_scene} = unchanged(changed)
    end
  end

  test "the recorder sees owned stock and replaces the obsolete ground description without changing rules" do
    world = recorded_inventory()
    world = %{world | scene: "En el sendero brilla un botón de latón."}
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          context = inspect(messages, limit: :infinity)

          send(
            parent,
            {:inventory_scene_context, String.contains?(context, "Inventario: botón de latón ×1"),
             String.contains?(context, "no dejes")}
          )

          tool_calls([
            call("final_result", %{
              "scene" => "El sendero de tierra sube hacia la cuesta del norte."
            })
          ])
        end
      ]
    }

    assert {:ok, ^world, "El sendero de tierra sube hacia la cuesta del norte.", _} =
             SceneRefresh.propose(model, world, [])

    assert_receive {:inventory_scene_context, true, true}
    assert [%{qty: 1}] = world.characters["Mara"].inventory
  end

  @tag :capture_log
  test "unchanged confirmation commits only against the exact reviewed world" do
    world = recorded_inventory()

    session =
      start_session(
        world: world,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Mara")]
      )

    assert {:ok, "dm"} = Session.start(session)
    state = %{session: session, game_id: 0}
    proposal = unchanged(world)
    assert {:unchanged_inventory, ^world, _} = proposal
    assert SceneRefresh.commit(state, proposal) == state
    assert Session.read_state(session) == %{world | scene_refresh_pending: false}
    changed = %{world | elapsed_seconds: 10}
    assert {:ok, _} = Session.update_state(session, "dm", fn _ -> {:ok, changed} end)
    assert SceneRefresh.commit(state, proposal) == state
    assert Session.read_state(session) == changed
    assert changed.scene_refresh_pending
  end
end
