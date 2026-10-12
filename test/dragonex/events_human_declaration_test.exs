defmodule Dragonex.EventsHumanDeclarationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Events, Games, History}
  alias Dragonex.Test.ModelMessages
  alias ExAgent.Message
  alias ExAgent.Message.{Part, Response}

  @declaration "Le entrego a Berta su campanilla y le digo: «Aquí tienes»."

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(title: "Voz humana propia", roster: [{Archetypes.fighter(), :human}])

    beat = %{
      game_id: game.id,
      actor: "Thane",
      turn_id: "declared",
      human_declaration: @declaration
    }

    %{game: game, deps: %{beat: beat}, baseline: Games.list_events(game.id)}
  end

  defp declared_speech(game),
    do: Enum.filter(Games.list_events(game.id), &(&1.payload["turn_id"] == "declared"))

  test "intermediate human prose is absent while native tool identities and prior messages survive",
       %{game: game, deps: deps, baseline: baseline} do
    old = Message.new_response([%Part.Text{content: "Crónica anterior, intacta."}])

    call = %Part.ToolCall{
      tool_name: "make_attack",
      args: %{"attacker" => "Thane"},
      tool_call_id: "native-attack"
    }

    response =
      Message.new_response([%Part.Text{content: "Thane sonríe y promete pagar."}, call],
        finish_reason: :tool_calls
      )

    state = %{deps: deps, messages: [old, response]}
    changed = Events.after_model_request(Events, state)
    assert [^old, latest] = changed.messages
    assert latest == %{response | parts: [call]}
    assert Response.tool_calls(latest) == [call]
    assert Games.list_events(game.id) == baseline
    assert Games.completed_narration(game.id, "Thane", "declared") == nil
  end

  test "completed resolution publishes exactly the source intent, never generated words or gestures",
       %{game: game, deps: deps} do
    response =
      Message.new_response([%Part.Text{content: "«Ya la tengo», digo, sin soltarla del todo."}],
        finish_reason: :stop
      )

    changed = Events.after_model_request(Events, %{deps: deps, messages: [response]})
    assert Response.text(List.last(changed.messages)) == @declaration

    assert [
             %{
               actor: "Thane",
               payload: %{
                 "text" => @declaration,
                 "complete" => true,
                 "kind" => "human_declaration"
               }
             }
           ] = declared_speech(game)

    assert Games.completed_narration(game.id, "Thane", "declared") == @declaration
    projected = History.from_events(declared_speech(game)) |> ModelMessages.project()
    assert [%{"role" => "user", "content" => context}] = projected
    assert context =~ "Thane declara" and context =~ @declaration
    refute context =~ "sin soltarla"
  end

  test "truncation and filtering cannot publish a completion or a model preview", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    for reason <- [:length, :content_filter, :unknown, :incomplete, :error] do
      response =
        Message.new_response([%Part.Text{content: "Una frase incompleta."}],
          finish_reason: reason
        )

      changed = Events.after_model_request(Events, %{deps: deps, messages: [response]})
      assert List.last(changed.messages).finish_reason == reason
      assert Response.text(List.last(changed.messages)) == ""
      assert Games.completed_narration(game.id, "Thane", "declared") == nil
    end

    assert Games.list_events(game.id) == baseline
  end

  test "the durable declaration is scoped to the game, actor, public audience and exact turn", %{
    game: game
  } do
    {:ok, _} =
      Games.append_event(game.id, :action, "Thane", "all", %{
        text: @declaration,
        turn_id: "declared"
      })

    {:ok, _} =
      Games.append_event(game.id, :action, "Thane", "all", %{
        text: "Otra acción.",
        turn_id: "other"
      })

    {:ok, _} =
      Games.append_event(game.id, :action, "Thane", "dm", %{text: "Privado.", turn_id: "declared"})

    assert Games.declaration_for_turn(game.id, "Thane", "declared") == @declaration
    assert Games.declaration_for_turn(game.id, "Vex", "declared") == nil
    assert Games.declaration_for_turn(game.id, "Thane", "missing") == nil
    {:ok, other} = Games.create_game(title: "Otra mesa", roster: [{Archetypes.fighter(), :human}])
    assert Games.declaration_for_turn(other.id, "Thane", "declared") == nil
  end

  test "a human declaration keeps typed names, dice notation and UTF-8 without becoming confirmed fact",
       %{game: game, deps: deps} do
    text = "Le digo a Vex: «Si saco 1d20, ¿me ayudas?» No digo que me siga."
    deps = put_in(deps.beat.human_declaration, text)
    response = Message.new_response([%Part.Text{content: "Vex acepta y Thane celebra."}])
    Events.after_model_request(Events, %{deps: deps, messages: [response]})
    assert Games.completed_narration(game.id, "Thane", "declared") == text
    assert String.valid?(Games.completed_narration(game.id, "Thane", "declared"))
    assert Games.load_world(Games.get_game(game.id)).facts == []
  end

  test "empty output or a cancelled owner cannot complete or publish a human voice", %{
    game: game,
    deps: deps,
    baseline: baseline
  } do
    empty = Message.new_response([])
    changed = Events.after_model_request(Events, %{deps: deps, messages: [empty]})
    assert changed.messages == [empty]
    assert Games.list_events(game.id) == baseline
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    response = Message.new_response([%Part.Text{content: "Palabras inventadas."}])
    dead = Map.put(deps, :game_owner, owner)
    changed = Events.after_model_request(Events, %{deps: dead, messages: [response]})
    assert Response.text(List.last(changed.messages)) == @declaration
    assert Games.list_events(game.id) == baseline
    assert Games.completed_narration(game.id, "Thane", "declared") == nil
  end

  test "a durable declaration outside the recent window is still the same turn", %{game: game} do
    {:ok, _} =
      Games.append_event(game.id, :action, "Thane", "all", %{
        text: @declaration,
        turn_id: "declared"
      })

    for n <- 1..401 do
      {:ok, _} = Games.append_event(game.id, :system, "system", "all", %{note: "Entrada #{n}."})
    end

    refute Enum.any?(Games.recent_events(game.id, 400), &(&1.payload["turn_id"] == "declared"))
    assert Games.declaration_for_turn(game.id, "Thane", "declared") == @declaration
  end
end
