defmodule Dragonex.WaitSceneConfirmationTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, World}
  alias Dragonex.Game.SceneRefresh
  alias ExAgent.{Models.Test, Session}

  defp interval do
    before =
      World.new(
        scene: "La barra de la taberna está tranquila.",
        characters: %{"Thane" => Archetypes.fighter()}
      )

    request = %{source_turn_id: "wait-source", seconds: 180, clock_before: 0}
    {:ok, pending} = World.resolve_wait("wait-source", 180, 180).(before)
    {before, pending, request}
  end

  defp recording(scene),
    do: %Test{script: [tool_calls([call("final_result", %{"scene" => scene})])]}

  defp opts(before, request), do: [wait_before: before, wait_resolution: request]

  test "a structured identical result confirms a resolved wait without claiming a new scene" do
    {before, pending, request} = interval()
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:wait_confirmation_context, inspect(messages, limit: :infinity)})
          tool_calls([call("final_result", %{"scene" => pending.scene})])
        end
      ]
    }

    assert pending.scene_refresh_pending

    assert {:unchanged_wait, ^pending, ^before, ^request, _usage} =
             SceneRefresh.propose(model, pending, [], opts(before, request))

    assert_receive {:wait_confirmation_context, context}
    assert context =~ "CONFIRMACIÓN DE ENTORNO TRAS ESPERA"
    assert context =~ "EXACTAMENTE la escena actual"

    assert pending.elapsed_seconds == 180
    assert pending.scene == before.scene
    {:ok, partial} = World.resolve_wait("wait-source", 180, 60).(before)

    assert {:unchanged_wait, ^partial, ^before, ^request, _usage} =
             SceneRefresh.propose(recording(partial.scene), partial, [], opts(before, request))

    assert partial.elapsed_seconds == 60
  end

  test "other changes, earlier pending reviews and mismatched receipts cannot clear the review" do
    {before, pending, request} = interval()
    {:ok, fact} = World.add_fact("Un desconocido paga al herrero.").(pending)
    {:ok, effect} = World.set_inspired("Thane", true).(pending)
    earlier = %{before | scene_refresh_pending: true}
    {:ok, earlier_wait} = World.resolve_wait("wait-source", 180, 180).(earlier)

    for {initial, current, source} <- [
          {earlier, earlier_wait, request},
          {before, fact, request},
          {before, effect, request},
          {before, %{pending | scene: "El patio de la posada."}, request},
          {before, pending, %{request | source_turn_id: "another-source"}},
          {before, pending, %{request | seconds: 300}},
          {before, pending, %{request | clock_before: 60}},
          {before, %{pending | elapsed_seconds: 240}, request}
        ] do
      assert {:error, :unchanged_scene} ==
               SceneRefresh.propose(recording(current.scene), current, [], opts(initial, source))
    end
  end

  test "confirmation changes only the pending flag and survives JSON with the receipt intact" do
    {before, pending, request} = interval()

    session =
      start_session(
        world: pending,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Thane", :human)]
      )

    assert {:ok, "dm"} = Session.start(session)
    state = %Dragonex.Game{game_id: 0, session: session}
    result = {:unchanged_wait, pending, before, request, nil}
    assert SceneRefresh.commit(state, result) == state
    world = Session.read_state(session)
    assert world == %{pending | scene_refresh_pending: false}
    assert world.log == before.log
    assert world.wait_resolution == pending.wait_resolution

    assert world |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode() ==
             world
  end

  test "a delayed confirmation cannot clear a newly pending fact or overwrite changed World" do
    {before, pending, request} = interval()

    session =
      start_session(
        world: pending,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Thane", :human)]
      )

    assert {:ok, "dm"} = Session.start(session)

    assert {:ok, changed} =
             Session.update_state(session, "dm", World.add_fact("La puerta acaba de abrirse."))

    state = %Dragonex.Game{game_id: 0, session: session}
    result = {:unchanged_wait, pending, before, request, nil}
    assert SceneRefresh.commit(state, result) == state
    assert Session.read_state(session) == changed
    assert changed.scene_refresh_pending
  end

  test "a changed fact receives no permission to reuse the previous surroundings" do
    {before, pending, request} = interval()
    {:ok, changed} = World.add_fact("La puerta acaba de abrirse.").(pending)
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:changed_scene_context, inspect(messages, limit: :infinity)})
          tool_calls([call("final_result", %{"scene" => changed.scene})])
        end
      ]
    }

    assert {:error, :unchanged_scene} =
             SceneRefresh.propose(model, changed, [], opts(before, request))

    assert_receive {:changed_scene_context, context}
    refute context =~ "CONFIRMACIÓN DE ENTORNO TRAS ESPERA"
  end

  test "a persisted fingerprint confirms after the original in-memory baseline is lost" do
    {before, pending, request} = interval()
    restored = pending |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert is_binary(restored.wait_resolution["scene_review_fingerprint"])
    assert String.length(restored.wait_resolution["scene_review_fingerprint"]) == 64

    assert {:unchanged_wait, ^restored, nil, ^request, _} =
             SceneRefresh.propose(recording(restored.scene), restored, [],
               wait_resolution: request
             )

    assert restored.characters == before.characters

    {:ok, changed} = World.add_fact("Un desconocido paga al herrero.").(restored)

    assert {:error, :unchanged_scene} ==
             SceneRefresh.propose(recording(changed.scene), changed, [], wait_resolution: request)
  end

  test "an invalid optional fingerprint cannot discard a valid clock receipt or authorize confirmation" do
    {_before, pending, request} = interval()

    for value <- ["bad-hash", 123, %{"invalid" => true}] do
      encoded = Codec.encode(pending)
      encoded = put_in(encoded, ["wait_resolution", "scene_review_fingerprint"], value)
      restored = Codec.decode(encoded)
      assert restored.wait_resolution["source_turn_id"] == request.source_turn_id
      assert restored.wait_resolution["scene_review_fingerprint"] == nil
      assert {:ok, ^restored} = World.resolve_wait(request.source_turn_id, 180, 180).(restored)

      assert {:error, :unchanged_scene} ==
               SceneRefresh.propose(recording(restored.scene), restored, [],
                 wait_resolution: request
               )
    end
  end
end
