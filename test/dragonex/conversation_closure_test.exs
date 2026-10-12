defmodule Dragonex.ConversationClosureTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Codec, Conversation, Text, World}
  alias Dragonex.Game.ConversationClosure

  @question "Lyra, Vex, ¿qué recordáis del combate? Espero vuestras respuestas antes de decidir."
  @names ["Lyra", "Vex"]
  @multiple "Lyra, Vex, ¿qué cambia la última aclaración del zagal para nuestra pista del hilo? ¿Qué proponéis hacer ahora y por qué? Espero vuestras respuestas antes de decidir."

  defp fixture(question \\ @question) do
    before =
      World.new(
        characters: %{
          "Thane" => Archetypes.fighter(),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue()
        }
      )

    state = %Dragonex.Game{participants: %{"Thane" => %{kind: :human}}}
    {:ok, asked} = Conversation.request("Thane", @names, question).(before)
    action = %{seq: 17, type: :action, actor: "Thane", payload: %{"text" => question}}
    asked = ConversationClosure.reserve(state, "Thane", question, before, asked, action)
    {:ok, pending} = Conversation.finish_actor("Lyra").(asked)
    {:ok, ready} = Conversation.finish_actor("Vex").(pending)

    events = [
      action,
      %{
        seq: 18,
        type: :narration,
        actor: "Thane",
        payload: %{"complete" => true, "text" => "—Recuerdo la flecha."}
      },
      %{
        seq: 19,
        type: :system,
        actor: "system",
        payload: %{"kind" => "give_turn_to", "to" => "Lyra"}
      },
      %{seq: 20, type: :turn, actor: "Lyra", payload: %{"phase" => "exploration"}},
      %{
        seq: 21,
        type: :narration,
        actor: "Lyra",
        payload: %{"complete" => true, "text" => "—Recuerdo la flecha."}
      },
      %{
        seq: 22,
        type: :system,
        actor: "system",
        payload: %{"kind" => "give_turn_to", "to" => "Vex"}
      },
      %{seq: 23, type: :turn, actor: "Vex", payload: %{"phase" => "exploration"}},
      %{
        seq: 24,
        type: :narration,
        actor: "Vex",
        payload: %{"complete" => true, "text" => "—Recuerdo la flecha."}
      }
    ]

    {state, before, asked, ready, events}
  end

  test "informative questions and opinions can close; action requests and extra declarations retain DM" do
    for text <- [
          @question,
          "Lyra y Vex, ¿qué preferís hacer? Espero las respuestas."
        ] do
      assert Text.pc_question_only?(text, @names)
    end

    for text <- [
          "Vex, ¿puedes abrir la puerta?",
          @question <> " Lanzo un hechizo.",
          "Vex, ¿qué viste? Espero cinco minutos.",
          "Vex, ¿qué viste? Lyra, ¿qué oíste?",
          "Vex, ¿qué viste, Maribel?",
          "Vex, ¿qué viste; y qué dice la posadera?",
          "La nota dice «Vex, ¿qué viste?».",
          nil
        ] do
      refute Text.pc_question_only?(text, @names), inspect(text)
    end

    refute Text.pc_question_only?("Mara, ¿qué prefieres?", ["Mara del Río", "Mara del Bosque"])
  end

  test "the world proof survives JSON and closes only the completed requested exchange" do
    {state, before, asked, ready, events} = fixture()
    assert asked.conversation["quiet_close"]["action_seq"] == 17
    assert Codec.decode(Jason.decode!(Jason.encode!(Codec.encode(asked)))) == asked

    assert ConversationClosure.fingerprint(Codec.decode(Codec.encode(before))) ==
             ConversationClosure.fingerprint(before)

    assert {:ok, closed} = ConversationClosure.finish(state, ready, events)
    assert closed.conversation["stage"] == "return"
    assert Map.drop(closed, [:conversation]) == Map.drop(before, [:conversation])
    assert {:ok, ^asked} = ConversationClosure.finish(state, asked, events)
  end

  test "multiple informative questions retain the same durable proof and consequence checks" do
    {state, before, asked, ready, events} = fixture(@multiple)
    assert asked.conversation["quiet_close"]["action_seq"] == 17
    assert Codec.decode(Codec.encode(asked)) == asked
    assert {:ok, closed} = ConversationClosure.finish(state, ready, events)
    assert closed.conversation["stage"] == "return"
    assert Map.drop(closed, [:conversation]) == Map.drop(before, [:conversation])

    changed = %{ready | elapsed_seconds: ready.elapsed_seconds + 1}
    assert {:ok, ^changed} = ConversationClosure.finish(state, changed, events)
    dice = events ++ [%{seq: 25, type: :dice, actor: "Lyra", payload: %{}}]
    assert {:ok, ^ready} = ConversationClosure.finish(state, ready, dice)

    question = put_in(events, [Access.at(4), :payload, "text"], "—Posadera, ¿puedes traer agua?")
    assert {:ok, ^ready} = ConversationClosure.finish(state, ready, question)
  end

  test "time, facts, scene, vitality, reserves and logs cannot be hidden by a quiet closure" do
    {state, before, _asked, ready, events} = fixture()

    for changed <- [
          %{ready | elapsed_seconds: ready.elapsed_seconds + 1},
          %{ready | facts: ["Un mensajero llegó."]},
          %{ready | scene: "El patio de la posada."},
          %{ready | scene_refresh_pending: true},
          put_in(ready.characters["Thane"].hp, 1),
          %{ready | spell_slots: %{"Lyra" => %{1 => 0}}},
          %{ready | rest_state: %{"Thane" => %{"hit_dice_spent" => 1}}},
          %{ready | log: [{"Lyra", "Una acción ya resuelta."} | before.log]},
          %{ready | phase: :combat}
        ] do
      assert {:ok, ^changed} = ConversationClosure.finish(state, changed, events)
    end

    checkpointed = %{ready | actor_checkpoint: %{"actor" => "Vex", "turn_id" => "receipt"}}
    assert {:ok, closed} = ConversationClosure.finish(state, checkpointed, events)
    assert closed.conversation["stage"] == "return"
  end

  test "a no-effect die, failed or partial speech, another declaration and missing history retain DM" do
    {state, _before, _asked, ready, events} = fixture()

    additions = [
      %{seq: 25, type: :dice, actor: "Lyra", payload: %{}},
      %{seq: 25, type: :system, actor: "system", payload: %{"note" => "El actor falló."}},
      %{seq: 25, type: :action, actor: "Cora", payload: %{"text" => "Yo también pregunto."}},
      %{seq: 25, type: :narration, actor: "Vex", payload: %{"complete" => false}},
      %{
        seq: 25,
        type: :narration,
        actor: "Cora",
        payload: %{"complete" => true, "text" => "—Recuerdo la flecha."}
      }
    ]

    variants =
      Enum.map(additions, &(events ++ [&1])) ++
        [
          tl(events),
          Enum.drop(events, -1),
          put_in(events, [Access.at(0), :payload, "text"], "Otra pregunta."),
          put_in(events, [Access.at(4), :payload, "text"], "—Posadera, ¿puedes llenar la jarra?"),
          events ++ [List.last(events)],
          put_in(events, [Access.at(4), :payload, "complete"], false)
        ]

    for changed <- variants,
        do: assert({:ok, ^ready} = ConversationClosure.finish(state, ready, changed))
  end

  test "manual participation and an unclaimed floor are revalidated at settlement" do
    {state, _before, _asked, ready, events} = fixture()

    for changed <- [
          %{state | pc_agents: %{"Thane" => self()}},
          %{state | participants: %{"Thane" => %{kind: :agent}}},
          %{state | pending_mini: true},
          %{state | last_was_mini: true},
          %{state | tm_reeval: true},
          %{state | interrupted: "Cora"},
          %{state | intents: %{"Cora" => "Otra declaración."}}
        ] do
      assert {:ok, ^ready} = ConversationClosure.finish(changed, ready, events)
    end

    legacy = update_in(ready.conversation, &Map.delete(&1, "quiet_close"))
    assert {:ok, ^legacy} = ConversationClosure.finish(state, legacy, events)
  end

  test "legacy and malformed proofs cannot erase valid questions or mark NPC requests quiet" do
    {_state, _before, asked, _ready, _events} = fixture()
    receipt = asked.conversation["quiet_close"]

    for bad <- [
          nil,
          %{},
          %{receipt | "action_seq" => 0},
          %{receipt | "action_seq" => "17"},
          %{receipt | "world_fingerprint" => "not-a-hash"}
        ] do
      decoded = Conversation.decode(Map.put(asked.conversation, "quiet_close", bad))
      assert decoded["question"] == @question
      refute Map.has_key?(decoded, "quiet_close")
    end

    decoded =
      Conversation.decode(put_in(asked.conversation, ["quiet_close", "secret"], "ignored"))

    assert decoded["quiet_close"] == receipt

    {:ok, npc} =
      Conversation.request_world("Thane", "la posadera", "¿Qué viste?").(
        World.new(characters: %{"Thane" => Archetypes.fighter()})
      )

    decoded = Conversation.decode(Map.put(npc.conversation, "quiet_close", receipt))
    assert decoded["world_recipient"] == "la posadera"
    refute Map.has_key?(decoded, "quiet_close")
  end
end
