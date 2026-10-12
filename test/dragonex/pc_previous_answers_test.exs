defmodule Dragonex.PCPreviousAnswersTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Archetypes, Codec, Conversation, PCAgent, World}

  @question "Lyra, Vex, ¿qué dijo el testigo y qué sigue sin probar?"
  @answer "Según el testigo, vio un abrigo oscuro; no reconoció de cerca la tela."

  defp asked do
    world =
      World.new(
        characters: %{
          "Mara" => Archetypes.wizard(name: "Mara"),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue()
        }
      )

    {:ok, world} = Conversation.request("Mara", ["Lyra", "Vex"], @question).(world)

    world =
      put_in(world.conversation["quiet_close"], %{
        "action_seq" => 10,
        "world_fingerprint" => String.duplicate("a", 64)
      })

    {:ok, world} = Conversation.finish_actor("Lyra").(world)
    world
  end

  defp event(seq, actor, text, opts \\ []) do
    %{
      seq: seq,
      actor: actor,
      type: Keyword.get(opts, :type, :narration),
      visible_to: Keyword.get(opts, :visibility, "all"),
      payload: %{"text" => text, "complete" => Keyword.get(opts, :complete, true)}
    }
  end

  defp anchor, do: event(10, "Mara", @question, type: :action)

  test "only earlier recipients' complete public interventions after the exact action are projected" do
    world = asked()
    before = Codec.encode(world)

    events = [
      event(1, "Mara", @question, type: :action),
      event(2, "Lyra", "OTRA PREGUNTA"),
      anchor(),
      event(11, "Lyra", "SECRETO", visibility: "dm"),
      event(12, "Lyra", "BORRADOR", complete: false),
      event(13, "Lyra", @answer),
      event(14, "Vex", "MI RESPUESTA ANTERIOR"),
      event(15, "dm", "CIERRE AJENO")
    ]

    guidance = PCAgent.response_guidance(world, "Vex", events)
    assert guidance =~ "Lyra: #{@answer}"
    assert guidance =~ "no son hechos confirmados"
    assert guidance =~ "añade solo lo que falte"

    for excluded <- [
          "OTRA PREGUNTA",
          "SECRETO",
          "BORRADOR",
          "MI RESPUESTA ANTERIOR",
          "CIERRE AJENO"
        ],
        do: refute(guidance =~ excluded)

    assert Codec.encode(world) == before
    assert Codec.decode(before) == world
  end

  test "missing or mismatched anchors and completed actors without published speech do not imply an answer" do
    world = asked()

    for events <- [
          [],
          [event(9, "Mara", @question, type: :action), event(13, "Lyra", @answer)],
          [event(10, "Mara", "OTRA PREGUNTA", type: :action), event(13, "Lyra", @answer)],
          [event(10, "Vex", @question, type: :action), event(13, "Lyra", @answer)],
          [event(10, "Mara", @question), event(13, "Lyra", @answer)],
          [anchor(), event(13, "Lyra", @answer, visibility: "Lyra")],
          [anchor(), event(13, "Lyra", @answer, complete: false)]
        ] do
      refute PCAgent.response_guidance(world, "Vex", events) =~
               "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
    end

    legacy = put_in(world.conversation, Map.delete(world.conversation, "quiet_close"))

    refute PCAgent.response_guidance(legacy, "Vex", [anchor(), event(13, "Lyra", @answer)]) =~
             "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
  end

  test "projection scrubs speech, keeps the full uncertainty and omits oversized speech without cutting its ending" do
    world = asked()
    short = "[Lyra]: El goblin está en 3/7 pg. Según el testigo, podría ser; no lo sabe."
    long = String.duplicate("x", 1801) <> " No puedo confirmarlo."
    guidance = PCAgent.response_guidance(world, "Vex", [anchor(), event(13, "Lyra", short)])
    refute guidance =~ "3/7"
    refute guidance =~ "[Lyra]:"
    assert guidance =~ "Según el testigo, podría ser; no lo sabe."

    refute PCAgent.response_guidance(world, "Vex", [anchor(), event(13, "Lyra", long)]) =~
             "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
  end

  test "first answer, combat, fallen or wrong actors receive no exchange projection" do
    world = asked()
    events = [anchor(), event(13, "Lyra", @answer)]

    for {world, actor} <- [
          {%{world | phase: :combat}, "Vex"},
          {put_in(world.characters["Vex"].hp, 0), "Vex"},
          {world, "Lyra"},
          {world, "dm"}
        ] do
      assert PCAgent.response_guidance(world, actor, events) == ""
    end

    first = put_in(world.conversation["pending"], ["Lyra", "Vex"])

    refute PCAgent.response_guidance(first, "Lyra", events) =~
             "INTERVENCIONES YA PUBLICADAS TRAS ESTA PREGUNTA"
  end
end
