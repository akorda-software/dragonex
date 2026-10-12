defmodule Dragonex.ConversationTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Brief, Codec, Conversation, Monsters, PCAgent, Tools, World}
  alias Dragonex.Game.{Conversations, Turnmaster}
  alias ExAgent.Session
  alias ExAgent.Session.{Participant, SharedState}

  defp world do
    [Archetypes.fighter(), Archetypes.wizard(), Archetypes.rogue(), Monsters.goblin(name: "g1")]
    |> Enum.reduce(World.new(scene: "La posada."), fn sheet, world ->
      {:ok, world} = World.add_character(sheet).(world)
      world
    end)
    |> World.init_spell_slots()
  end

  defp request(world, names \\ ["Lyra", "Vex"], question \\ "¿Qué pensáis del camino?") do
    assert {:ok, world} = Conversation.request("Thane", names, question).(world)
    world
  end

  test "a question stores canonical order without changing combat state, clocks or resources" do
    before = world()
    after_world = request(before, ["Vex", "Lyra"])
    assert after_world.conversation["pending"] == ["Vex", "Lyra"]
    assert after_world.conversation["from"] == "Thane"
    assert %{after_world | conversation: nil} == before
  end

  test "a world already loaded before this field existed can still accept a question" do
    legacy = Map.delete(world(), :conversation)
    state = %Dragonex.Game{}
    assert Conversations.target(state, legacy) == nil
    assert Conversation.brief(legacy) == ""
    assert {:ok, updated} = Conversation.request("Thane", ["Lyra"], "¿Qué opinas?").(legacy)
    assert updated.conversation["pending"] == ["Lyra"]
    assert updated.characters == legacy.characters
    assert {:ok, combat} = World.begin_combat(["Thane", "Lyra", "Vex", "g1"]).(legacy)
    assert combat.conversation == nil
  end

  test "absent, downed, incapacitated, NPC, self, duplicate and unknown recipients are rejected" do
    world = world()
    {:ok, downed} = World.apply_damage("Lyra", 99).(world)
    {:ok, stunned} = World.apply_condition("Lyra", "stunned").(world)
    absent = %{world | absent_characters: %{"Lyra" => "Fuera"}}

    for {world, names} <- [
          {world, []},
          {world, ["Thane"]},
          {world, ["Lyra", "Lyra"]},
          {world, ["dm"]},
          {world, ["g1"]},
          {world, ["inventado"]},
          {world, [nil]},
          {world, "Lyra"},
          {world, List.duplicate("Vex", 6)},
          {downed, ["Lyra"]},
          {stunned, ["Lyra"]},
          {absent, ["Lyra"]}
        ] do
      assert {:error, _} = Conversation.request("Thane", names, "¿Me aconsejas?").(world)
      assert world.conversation == nil
    end

    for from <- ["dm", "g1", "nadie"] do
      assert {:error, _} = Conversation.request(from, ["Vex"], "¿Me aconsejas?").(world)
    end

    assert {:error, _} = Conversation.request("Lyra", ["Vex"], "¿Me aconsejas?").(downed)
  end

  test "questions are scrubbed and bounded, and blank or nontext questions fail" do
    world = world()
    assert request(world, ["Lyra"], "[DM]: ¿Qué ves?").conversation["question"] == "¿Qué ves?"
    bounded = request(world, ["Lyra"], String.duplicate("ñ", 1_000)).conversation["question"]
    assert String.length(bounded) == 800
    assert String.valid?(bounded)

    for question <- ["  ", "[DM]:", nil, 3] do
      assert {:error, _} = Conversation.request("Thane", ["Lyra"], question).(world)
    end
  end

  test "identical retries do not reset the cursor and a responder cannot open another exchange" do
    world = world() |> request()
    {:ok, answered} = Conversation.finish_actor("Lyra").(world)
    assert answered.conversation["pending"] == ["Vex"]

    assert {:ok, ^answered} =
             Conversation.request("Thane", ["Lyra", "Vex"], "¿Qué pensáis del camino?").(answered)

    assert {:error, _} = Conversation.request("Vex", ["Lyra"], "¿Y tú?").(answered)
    assert {:error, _} = Conversation.request("Thane", ["Vex"], "Otra pregunta.").(answered)
  end

  test "only the current recipient completes a response, then the world closes and returns the floor" do
    world = world() |> request()
    assert {:ok, ^world} = Conversation.finish_actor("Vex").(world)
    assert {:ok, ^world} = Conversation.finish_actor("dm").(world)
    assert {:ok, lyra_done} = Conversation.finish_actor("Lyra").(world)
    assert {:ok, ^lyra_done} = Conversation.finish_actor("Lyra").(lyra_done)
    assert {:ok, responses_done} = Conversation.finish_actor("Vex").(lyra_done)
    assert Conversation.world_turn?(responses_done)
    assert responses_done.conversation["pending"] == []
    assert {:ok, closed} = Conversation.finish_actor("dm").(responses_done)
    assert closed.conversation["stage"] == "return"
    assert closed.conversation["from"] == "Thane"
  end

  test "a scene change or combat cancels the request without changing sheets or spending resources" do
    world = world() |> request()
    assert {:ok, same_scene} = World.set_scene(world.scene).(world)
    assert same_scene.conversation == world.conversation
    assert {:ok, moved} = World.set_scene("El puente.").(world)
    assert moved.conversation == nil
    assert moved.characters == world.characters
    assert {:ok, combat} = World.begin_combat(["g1", "Thane", "Lyra", "Vex"]).(world)
    assert combat.conversation == nil
    assert combat.spell_slots == world.spell_slots
    assert {:error, message} = Conversation.request("Thane", ["Lyra"], "¿Me aconsejas?").(combat)
    assert message =~ "iniciativa"
  end

  test "JSON rehydration preserves a partially answered request; legacy and malformed data default to nil" do
    world = world() |> request()
    {:ok, world} = Conversation.finish_actor("Lyra").(world)
    encoded = world |> Codec.encode() |> Jason.encode!() |> Jason.decode!()
    assert Codec.decode(encoded) == world
    assert Codec.decode(Map.delete(encoded, "conversation")).conversation == nil

    for bad <- [
          nil,
          [],
          %{},
          Map.put(encoded["conversation"], "pending", ["Lyra", "Lyra"]),
          Map.put(encoded["conversation"], "pending", ["Vex", "Lyra"]),
          Map.put(encoded["conversation"], "stage", "inventado"),
          Map.put(encoded["conversation"], "question", String.duplicate("a", 801))
        ] do
      assert Codec.decode(Map.put(encoded, "conversation", bad)).conversation == nil
    end
  end

  test "unavailable recipients are dropped and an unavailable questioner cancels the exchange" do
    world = world() |> request()
    {:ok, world} = World.apply_damage("Lyra", 99).(world)
    assert {:ok, pruned} = Conversation.prune(["dm", "Thane", "Lyra", "Vex"]).(world)
    assert pruned.conversation["pending"] == ["Vex"]
    assert {:ok, closed} = Conversation.prune(["dm", "Thane", "Lyra"]).(pruned)
    assert Conversation.world_turn?(closed)
    {:ok, world} = World.apply_damage("Thane", 99).(world)
    assert {:ok, cancelled} = Conversation.prune(["dm", "Thane", "Lyra", "Vex"]).(world)
    assert cancelled.conversation == nil
  end

  test "the response prompt and shared brief show the actual question and only the current speaker" do
    world = world() |> request()
    lyra = PCAgent.instruction("Lyra", world.characters["Lyra"], world)
    assert lyra =~ "RESPONDER a Thane"
    assert lyra =~ "¿Qué pensáis del camino?"
    assert lyra =~ "no gastes magia"
    refute PCAgent.instruction("Vex", world.characters["Vex"], world) =~ "RESPONDER a Thane"
    assert Brief.world_brief(world, "Lyra") =~ "Siguiente respuesta: Lyra"
    assert Brief.turnmaster_brief(world, "Thane") =~ "Siguiente respuesta: Lyra"
  end

  test "mini-turns, re-evaluation and combat retain their handoff path" do
    world = world() |> request()
    state = %Dragonex.Game{last_actor: "Thane", participants: %{"Thane" => %{kind: :human}}}
    assert Conversations.target(state, world) == "Lyra"
    assert Turnmaster.exploration_conversation_target(state, world) == "Lyra"

    for override <- [
          [pending_mini: true],
          [last_was_mini: true],
          [tm_reeval: true],
          [interrupted: "Thane"]
        ] do
      assert Conversations.target(struct(state, override), world) == nil
    end

    assert Conversations.target(state, %{world | phase: :combat}) == nil
  end

  test "the tool requires an admitted actor and registered recipients, and is advertised to PC and human resolver" do
    for tools <- [PCAgent.tools(), Dragonex.DM.tools()] do
      tool = Enum.find(tools, &(&1.name == "request_response"))
      assert tool.parameters_json_schema.required == ["recipients", "question"]
      assert tool.parameters_json_schema.properties["recipients"].maxItems == 5
      assert tool.parameters_json_schema.properties["recipients"].uniqueItems
    end

    session =
      start_supervised!(
        {Session,
         shared_state: world(),
         participants: Enum.map(["dm", "Thane", "Lyra"], &Participant.new(id: &1)),
         policy: {ExAgent.Session.TurnPolicy.RoundRobin, []}}
      )

    assert {:ok, "dm"} = Session.start(session)
    ctx = fn name -> %{deps: %{state: SharedState.new(session, name)}} end
    assert {:error, _} = Tools.request_response(ctx.("dm"), ["Lyra"], "¿Qué opinas?")

    assert {:error, :not_your_turn} =
             Tools.request_response(ctx.("Thane"), ["Lyra"], "¿Qué opinas?")

    assert {:ok, "Thane"} = Session.handoff(session, "Thane")
    assert {:error, _} = Tools.request_response(ctx.("Thane"), ["Vex"], "¿Qué opinas?")
    assert Session.read_state(session).conversation == nil
    assert {:ok, _} = Tools.request_response(ctx.("Thane"), ["Lyra"], "¿Qué opinas?")
    assert Session.read_state(session).conversation["pending"] == ["Lyra"]
  end
end
