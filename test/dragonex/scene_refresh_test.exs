defmodule Dragonex.SceneRefreshTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Codec, Conversation, World, WorldClock}
  alias Dragonex.Game.SceneRefresh
  alias ExAgent.Models.Test
  alias ExAgent.Session

  defp world do
    World.new(
      scene: "El patio inicial. El encargo está pendiente.",
      characters: %{"Thane" => Archetypes.fighter(), "Vex" => Archetypes.rogue()}
    )
  end

  test "only established changes mark the scene pending, and that marker survives JSON" do
    initial = world()
    refute Map.get(initial, :scene_refresh_pending)
    assert WorldClock.advance(initial, 0) == initial
    timed = WorldClock.advance(initial, 28800)
    assert Map.get(timed, :scene_refresh_pending)
    assert timed.elapsed_seconds == 28800
    decoded = timed |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert decoded == timed
    {:ok, changed} = World.add_fact("El encargo terminó.").(initial)
    assert Map.get(changed, :scene_refresh_pending)
    assert {:ok, changed} == World.add_fact("El encargo terminó.").(changed)
    assert {:ok, initial} == World.add_fact(" ").(initial)
    {:ok, combat} = World.begin_combat(["Thane", "Vex"]).(initial)
    refute Map.get(WorldClock.advance(combat, 6), :scene_refresh_pending)
    {:ok, ended} = World.end_combat().(combat)
    assert Map.get(ended, :scene_refresh_pending)
  end

  test "legacy worlds with elapsed time or facts need a review without rewriting the scene" do
    encoded = Codec.encode(WorldClock.advance(world(), 28800))
    decoded = encoded |> Map.delete("scene_refresh_pending") |> Codec.decode()
    assert Map.get(decoded, :scene_refresh_pending)
    assert decoded.scene == world().scene
    fresh = world() |> Codec.encode() |> Map.delete("scene_refresh_pending") |> Codec.decode()
    refute Map.get(fresh, :scene_refresh_pending)
  end

  test "a recorded snapshot preserves the reply queue while a declared scene change still cancels it" do
    {:ok, pending} = Conversation.request("Thane", ["Vex"], "¿Qué opinas?").(world())
    pending = WorldClock.advance(pending, 3600)
    {:ok, recorded} = World.refresh_scene("La posada está en calma.").(pending)
    assert recorded.conversation == pending.conversation
    refute Map.get(recorded, :scene_refresh_pending)

    assert Map.drop(recorded, [:scene, :log, :scene_refresh_pending]) ==
             Map.drop(pending, [:scene, :log, :scene_refresh_pending])

    {:ok, moved} = World.set_scene("El bosque junto al camino.").(pending)
    assert moved.conversation == nil
    refute Map.get(moved, :scene_refresh_pending)
  end

  test "the recorder forces a bounded scene result and exposes no rule tools" do
    parent = self()
    pending = WorldClock.advance(world(), 28800)
    {:ok, pending} = World.add_fact("El encargo terminó y está pagado.").(pending)

    model = %Test{
      script: [
        fn messages, params ->
          send(parent, {:recording_request, messages, params})

          tool_calls([
            call("final_result", %{
              "scene" => "[DM]: El cuarto de la posada. El encargo está cerrado."
            })
          ])
        end
      ]
    }

    assert {:ok, ^pending, scene, _usage} = SceneRefresh.propose(model, pending, [])
    assert scene == "El cuarto de la posada. El encargo está cerrado."
    assert_receive {:recording_request, messages, params}
    assert params.output_mode == :tool
    refute params.allow_text_output
    assert params.function_tools == []
    assert [%{name: "final_result", parameters_json_schema: schema}] = params.output_tools
    assert schema.required == ["scene"]
    assert schema.properties["scene"].maxLength == 1200
    assert inspect(messages, limit: :infinity) =~ "28800 s"
    assert inspect(messages, limit: :infinity) =~ "El encargo terminó y está pagado."
  end

  test "a missing result is bounded and does not turn plain narration into a canonical scene" do
    pending = WorldClock.advance(world(), 3600)
    assert {:error, _} = SceneRefresh.propose(%Test{label: "Una mañana agradable."}, pending, [])
    assert pending.scene == world().scene
    assert Map.get(pending, :scene_refresh_pending)
  end

  test "empty scrubbed text and a PC relocation cannot become a scene snapshot" do
    pending = WorldClock.advance(world(), 3600)

    for scene <- [
          "[DM]:",
          pending.scene,
          "Thane cruza el umbral. La posada está en calma.",
          "El grupo cruza el puente."
        ] do
      model = %Test{script: [tool_calls([call("final_result", %{"scene" => scene})])]}
      assert {:error, _} = SceneRefresh.propose(model, pending, [])
    end
  end

  test "a stalled recorder times out without changing or replaying world operations" do
    pending = WorldClock.advance(world(), 3600)
    parent = self()

    model = %Test{
      script: [
        fn _, _ ->
          send(parent, {:recorder_started, self()})

          receive do
            :release -> "No llega a registrarse."
          end
        end
      ]
    }

    assert {:error, :timeout} = SceneRefresh.propose(model, pending, [], timeout: 30)

    # The overall deadline includes preparing the request. Under concurrent
    # suite load it may expire before the model callback starts at all.
    receive do
      {:recorder_started, recorder} ->
        ref = Process.monitor(recorder)
        assert_receive {:DOWN, ^ref, :process, ^recorder, _}, 1_000
    after
      0 -> :ok
    end

    assert pending == WorldClock.advance(world(), 3600)
  end

  test "an invalid structured result can be corrected without gaining rule tools" do
    parent = self()
    pending = WorldClock.advance(world(), 3600)

    model = %Test{
      script: [
        tool_calls([call("final_result", %{"scene" => String.duplicate("x", 1201)})]),
        fn _messages, params ->
          send(parent, {:retry_tools, params.function_tools})

          tool_calls([
            call("final_result", %{"scene" => "El cuarto tiene una ventana hacia el patio."})
          ])
        end
      ]
    }

    assert {:ok, ^pending, "El cuarto tiene una ventana hacia el patio.", _} =
             SceneRefresh.propose(model, pending, [])

    assert_receive {:retry_tools, []}
  end

  test "the bounded crossing guard preserves quoted invitations and a different NPC with the same prefix" do
    pending = WorldClock.advance(world(), 3600)

    pending = %{
      pending
      | characters:
          Map.put(pending.characters, "Vex del Muelle", %{
            Archetypes.rogue(name: "Vex del Muelle")
            | side: "monster"
          })
    }

    for scene <- [
          "La posadera dice: «Thane cruza el umbral cuando quieras». El patio está en calma.",
          "Vex del Muelle cruza el umbral. La posada está en calma."
        ] do
      model = %Test{script: [tool_calls([call("final_result", %{"scene" => scene})])]}
      assert {:ok, ^pending, ^scene, _} = SceneRefresh.propose(model, pending, [])
    end
  end

  test "a recorder response cannot overwrite a World that changed while it was running" do
    pending = WorldClock.advance(world(), 3600)

    session =
      start_session(
        world: pending,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Thane", :human), p("Vex")]
      )

    assert {:ok, "dm"} = Session.start(session)

    assert {:ok, changed} =
             Session.update_state(session, "dm", World.add_fact("La posadera acaba de llegar."))

    state = %Dragonex.Game{game_id: 0, session: session}
    result = {:ok, pending, "Una descripción anterior.", nil}
    assert SceneRefresh.commit(state, result) == state
    assert Session.read_state(session) == changed
    assert Map.get(changed, :scene_refresh_pending)
  end

  test "the live truncated summary and a numbered party's day cannot become the surroundings" do
    pending = WorldClock.advance(world(), 28800)

    partial =
      "Es de mañana en la posada rural. Los tres pasan el día en el cuarto de la esquina, con la ventana abierta al huerto donde el rocío brilla en los manzanos; más allá, el camino"

    for scene <- [partial, "Los tres pasan el día en el cuarto de la esquina."] do
      model = %Test{script: [tool_calls([call("final_result", %{"scene" => scene})])]}
      assert {:error, _} = SceneRefresh.propose(model, pending, [])
    end

    model = %Test{
      script: [
        tool_calls([call("final_result", %{"scene" => partial})]),
        tool_calls([
          call("final_result", %{
            "scene" => "El cuarto de la posada tiene una ventana hacia el huerto."
          })
        ])
      ]
    }

    assert {:ok, ^pending, "El cuarto de la posada tiene una ventana hacia el huerto.", _} =
             SceneRefresh.propose(model, pending, [])
  end
end
