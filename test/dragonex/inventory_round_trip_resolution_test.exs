defmodule Dragonex.InventoryRoundTripResolutionTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Codec, World}
  alias Dragonex.Game.InventoryResolution, as: Resolution

  @request %{actor: "Bran", kind: :round_trip, seq: 63}
  @declaration "Ada, ¿me prestas el sello un instante? Lo miro y se lo devuelvo inmediatamente."
  @round_trip {"record_item_round_trip",
               %{
                 "who" => "Bran",
                 "item" => "sello",
                 "quantity" => 1,
                 "direction" => "borrow_return"
               }}
  @grant {"grant_item", %{"who" => "Bran", "item" => "sello", "quantity" => 1}}
  @remove {"remove_item", %{"who" => "Bran", "item" => "sello", "quantity" => 1}}

  defp world(receipts \\ [], turn_id \\ "dm-turn") do
    %World{
      characters: %{"Bran" => %{Archetypes.fighter(name: "Bran") | inventory: []}},
      actor_checkpoint: %{
        "actor" => "dm",
        "turn_id" => turn_id,
        "phase" => "exploration",
        "enemies_before" => [],
        "mini_turn" => false,
        "pending_narration" => true,
        "tools" =>
          Enum.map(receipts, fn {name, args} ->
            %{"name" => name, "args" => args, "values" => ["registrado"]}
          end)
      }
    }
  end

  defp beat(receipts \\ []) do
    %{inventory_resolution: @request, tool_results: Map.new(receipts, &{&1, ["registrado"]})}
  end

  defp no_transfer(outcome, who \\ "Bran"),
    do:
      {"confirm_no_inventory_transfer",
       %{"who" => who, "outcome" => outcome, "reason" => "Ada no lo entrega"}}

  test "unchanged stock and ambiguous receipts cannot prove a temporary transfer" do
    before = world()
    refute Resolution.resolved?(before, @request, "dm-turn")

    for receipt <- [
          @grant,
          @remove,
          {"confirm_inventory_unchanged",
           %{"who" => "Bran", "reason" => "lo devuelve y el saldo queda igual"}},
          no_transfer("net_zero")
        ] do
      refute Resolution.resolved?(world([receipt]), @request, "dm-turn"), inspect(receipt)
    end

    # The old unordered map of receipts cannot prove the chronology or the
    # counterpart of a loan, even if both operation names are present.
    refute Resolution.resolved?(world([@grant, @remove]), @request, "dm-turn")
    assert world([@round_trip]).characters == before.characters
    assert Resolution.resolved?(world([@round_trip]), @request, "dm-turn")
  end

  test "only a typed decision for this player and current beat satisfies the request" do
    for outcome <- ~w(declined not_available look_only) do
      assert Resolution.resolved?(world([no_transfer(outcome)]), @request, "dm-turn")
      refute Resolution.resolved?(world([no_transfer(outcome, "Mara")]), @request, "dm-turn")
    end

    {name, args} = @round_trip
    refute Resolution.resolved?(world([{name, %{args | "who" => "Mara"}}]), @request, "dm-turn")
    refute Resolution.resolved?(world([@round_trip], "previous-turn"), @request, "dm-turn")
  end

  test "ordinary pickup receipts also belong to the player awaiting the answer" do
    request = %{@request | kind: :pickup}
    assert Resolution.resolved?(world([@grant]), request, "dm-turn")
    {name, args} = @grant
    refute Resolution.resolved?(world([{name, %{args | "who" => "Mara"}}]), request, "dm-turn")
  end

  test "new loans reject separate partial payments and the ambiguous no-change tool" do
    for key <- [@grant, @remove, {"confirm_inventory_unchanged", %{"who" => "Bran"}}] do
      assert {:error, message} = Resolution.validate_commit(beat(), key)
      assert message =~ "record_item_round_trip"
    end

    assert :ok = Resolution.validate_commit(beat(), @round_trip)
    assert :ok = Resolution.validate_commit(beat(), no_transfer("declined"))
    assert {:error, _} = Resolution.validate_commit(beat(), no_transfer("declined", "Mara"))
  end

  test "a paid decision blocks a second episode, changed arguments and the opposite outcome" do
    {name, args} = @round_trip

    for first <- [@round_trip, no_transfer("declined")],
        next <- [
          @round_trip,
          {name, %{args | "quantity" => 2}},
          no_transfer("look_only"),
          @grant,
          @remove
        ] do
      assert {:error, _} = Resolution.validate_commit(beat([first]), next)
    end

    # Exact replay is returned before this guard; the second commit of two
    # concurrently admitted identical calls must still fail without an effect.
    assert :ok = Resolution.validate_commit(beat(), @round_trip)
    assert {:error, _} = Resolution.validate_commit(beat([@round_trip]), @round_trip)
  end

  test "legacy partial receipts cannot authorize another loan or an invented no-transfer outcome" do
    for paid <- [[@grant], [@remove], [@grant, @remove]],
        next <- [@round_trip, no_transfer("look_only"), @grant, @remove] do
      assert {:error, message} = Resolution.validate_commit(beat(paid), next)
      assert message =~ "herramientas previas"
    end
  end

  test "a legacy request permits completing its old legs while refusing a second loan" do
    action = %{
      type: :action,
      actor: "Bran",
      seq: 63,
      visible_to: "all",
      payload: %{"text" => @declaration}
    }

    assert %{kind: :delivery} =
             legacy = Resolution.legacy_request("dm", world([@grant]), [action])

    assert Resolution.resolved?(world([@grant]), legacy, "dm-turn")
    legacy_beat = %{beat([@grant]) | inventory_resolution: legacy}
    assert :ok = Resolution.validate_commit(legacy_beat, @remove)
    assert {:error, _} = Resolution.validate_commit(legacy_beat, @round_trip)

    # The same text in a newly started beat still receives the strict contract.
    assert @request == Resolution.request("dm", world(), [action])
    assert {:error, _} = Resolution.validate_commit(beat(), @remove)
  end

  test "intermediate narration preserves the declaration; complete and legacy narration answer it" do
    action = %{
      type: :action,
      actor: "Bran",
      seq: 63,
      visible_to: "all",
      payload: %{"text" => @declaration}
    }

    narration = %{
      type: :narration,
      actor: "dm",
      seq: 67,
      visible_to: "all",
      payload: %{"text" => "Ada levanta la mirada.", "complete" => false}
    }

    assert @request == Resolution.request("dm", world(), [action])
    assert @request == Resolution.request("dm", world(), [action, narration])

    assert Resolution.request("dm", world(), [action, put_in(narration.payload["complete"], true)]) ==
             nil

    assert Resolution.request("dm", world(), [
             action,
             %{narration | payload: Map.delete(narration.payload, "complete")}
           ]) == nil
  end

  test "JSON keeps the committed no-transfer or round-trip receipt without relying on final stock" do
    for receipt <- [@round_trip, no_transfer("look_only")] do
      saved = world([receipt])
      restored = saved |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
      assert restored.characters == saved.characters
      assert Resolution.resolved?(restored, @request, "dm-turn")
      refute Resolution.resolved?(restored, @request, "other-turn")
    end
  end
end
