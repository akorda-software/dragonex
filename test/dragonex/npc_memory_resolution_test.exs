defmodule Dragonex.NPCMemoryResolutionTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Codec, Conversation, Text, World}
  alias Dragonex.Game.NPCMemoryResolution

  @question "Le pregunto al zagal: «Cuando dijiste que lo viste de lejos, ¿te referías al abrigo? ¿Llegaste a ver la lana?» Espero aquí su respuesta."
  @request %{speaker: "el zagal"}

  defp asked(question \\ @question) do
    world = World.new(characters: %{"Mara" => Archetypes.wizard(name: "Mara")})
    {:ok, asked} = Conversation.request_world("Mara", "el zagal", question).(world)
    asked
  end

  defp checkpoint(name \\ "record_npc_statement", speaker \\ "El zagal", turn \\ "current") do
    %{
      "actor" => "dm",
      "turn_id" => turn,
      "phase" => "exploration",
      "mini_turn" => false,
      "enemies_before" => [],
      "tools" => [
        %{
          "name" => name,
          "args" => %{"speaker" => speaker, "statement" => "No lo vi de cerca."},
          "values" => ["Testimonio confirmado por el motor."]
        }
      ]
    }
  end

  test "only a pending literal clarification identifies a mandatory source without changing world" do
    world = asked()
    before = Codec.encode(world)
    assert NPCMemoryResolution.request("dm", world) == @request
    assert {"el zagal", speech} = Text.literal_npc_clarification(@question)
    assert speech =~ "Cuando dijiste que lo viste de lejos"
    assert Codec.encode(world) == before
    assert NPCMemoryResolution.request("Mara", world) == nil
    assert NPCMemoryResolution.request("dm", %{world | phase: :combat}) == nil
    assert NPCMemoryResolution.request("dm", %{world | conversation: nil}) == nil
    ordinary = asked("Le pregunto al zagal: «¿Qué viste?»")
    assert NPCMemoryResolution.request("dm", ordinary) == nil
    assert Text.literal_npc_clarification(@question <> " Camino al molino.") == nil
  end

  test "only a committed receipt for this source and this DM turn resolves the request" do
    world = asked()

    for saved <- [
          nil,
          %{},
          checkpoint("establish_fact"),
          checkpoint("record_npc_statement", "Maribel"),
          checkpoint("record_npc_statement", "El zagal", "old"),
          Map.put(checkpoint(), "actor", "Mara"),
          put_in(checkpoint(), ["tools", Access.at(0), "values"], [])
        ] do
      refute NPCMemoryResolution.resolved?(
               %{world | actor_checkpoint: saved},
               @request,
               "current"
             )
    end

    recorded = %{world | actor_checkpoint: checkpoint()}
    assert NPCMemoryResolution.resolved?(recorded, @request, "current")
    restored = Codec.decode(Codec.encode(recorded))
    assert restored == recorded
    assert NPCMemoryResolution.resolved?(restored, @request, "current")
    refute NPCMemoryResolution.resolved?(restored, @request, "next")
  end

  test "existing facts alone do not substitute a current receipt and combat interruption is permitted" do
    world = %{asked() | facts: ["El zagal afirma: «No lo vi de cerca.»"]}
    refute NPCMemoryResolution.resolved?(world, @request, "current")
    assert NPCMemoryResolution.resolved?(world, nil, "current")
    assert NPCMemoryResolution.resolved?(%{world | phase: :combat}, @request, "current")
  end

  test "speaker validation preserves articles and spacing without merging different or shortened sources" do
    deps = %{beat: %{npc_memory_resolution: %{speaker: "el zagal de las cabras"}}}

    for speaker <- [
          "El zagal de las cabras",
          "zagal de las cabras",
          "  EL  ZAGAL DE LAS CABRAS  "
        ] do
      assert NPCMemoryResolution.validate_speaker(deps, speaker) == :ok
    end

    for speaker <- [nil, "Maribel", "El zagal", "El zagal de los cerdos"] do
      assert {:error, _} = NPCMemoryResolution.validate_speaker(deps, speaker)
    end

    assert NPCMemoryResolution.validate_speaker(%{}, "Maribel") == :ok
    refute NPCMemoryResolution.waiting?(%{})
  end
end
