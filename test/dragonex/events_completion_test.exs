defmodule Dragonex.EventsCompletionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Archetypes, Events, Games, History}
  alias ExAgent.Message
  alias ExAgent.Message.Part

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, game} =
      Games.create_game(title: "Respuestas completas", roster: [{Archetypes.fighter(), :human}])

    %{game: game}
  end

  defp publish(game, response, actor \\ "dm", turn_id \\ "one") do
    beat = %{
      game_id: game.id,
      actor: actor,
      turn_id: turn_id,
      pc_names: ["Thane"],
      character_names: ["Thane"]
    }

    state = %{deps: %{beat: beat}, messages: [response]}
    assert Events.after_model_request(Events, state) == state
  end

  defp speech(game),
    do: Enum.filter(Games.list_events(game.id), &(&1.payload["turn_id"] == "one"))

  test "completed speech is scrubbed and scoped to the exact game, actor and turn", %{game: game} do
    publish(
      game,
      Message.new_response([
        %Part.Text{content: "«Aceptamos», dice Thane. El patio está en calma."}
      ])
    )

    saved = Games.completed_narration(game.id, "dm", "one")
    assert saved =~ "El patio está en calma"
    refute saved =~ "Aceptamos"
    assert Games.completed_narration(game.id, "Thane", "one") == nil
    assert Games.completed_narration(game.id, "dm", "other") == nil

    {:ok, other} =
      Games.create_game(title: "Otra crónica", roster: [{Archetypes.fighter(), :human}])

    assert Games.completed_narration(other.id, "dm", "one") == nil
  end

  test "repeated intermediate declarations survive and never complete the beat", %{game: game} do
    declaration =
      Message.new_response([
        %Part.Text{content: "El goblin alza su espada."},
        %Part.ToolCall{tool_name: "make_attack", args: %{}}
      ])

    publish(game, declaration)
    publish(game, declaration)
    assert Games.completed_narration(game.id, "dm", "one") == nil
    events = speech(game)
    assert Enum.count(events, &(&1.type == :narration)) == 2
    assert Enum.all?(events, &(&1.payload["complete"] == false))
    publish(game, Message.new_response([%Part.Text{content: "El goblin retrocede."}]))
    assert Games.completed_narration(game.id, "dm", "one") == "El goblin retrocede."
    assert inspect(History.from_events(Games.list_events(game.id))) =~ "alza su espada"
  end

  test "truncated and filtered responses remain incomplete", %{game: game} do
    for reason <- [:length, :content_filter] do
      publish(
        game,
        Message.new_response([%Part.Text{content: "La escena queda a medias."}],
          finish_reason: reason
        )
      )

      assert Games.completed_narration(game.id, "dm", "one") == nil
    end

    assert length(speech(game)) == 2
  end

  test "empty and fully scrubbed speech do not create a completion receipt", %{game: game} do
    for raw <- ["", "  ", "«Aceptamos», dice Thane."] do
      publish(game, Message.new_response([%Part.Text{content: raw}]))
    end

    assert Games.completed_narration(game.id, "dm", "one") == nil
    assert speech(game) == []
  end

  test "legacy or malformed metadata never proves completion", %{game: game} do
    for payload <- [
          %{text: "Una narración antigua.", turn_id: "one"},
          %{text: "Un marcador inválido.", turn_id: "one", complete: "true"},
          %{text: "", turn_id: "one", complete: true},
          %{text: 12, turn_id: "one", complete: true}
        ] do
      assert {:ok, _} = Games.append_event(game.id, :narration, "dm", "all", payload)
      assert Games.completed_narration(game.id, "dm", "one") == nil
    end
  end
end
