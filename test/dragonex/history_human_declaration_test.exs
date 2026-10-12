defmodule Dragonex.HistoryHumanDeclarationTest do
  use ExUnit.Case, async: true
  alias Dragonex.{History, Games.GameEvent}
  alias Dragonex.Test.ModelMessages

  test "the literal human voice remains an intent beside dice and the DM's confirmed response" do
    events = [
      %GameEvent{
        type: :narration,
        actor: "Thane",
        payload: %{"text" => "Ataco al bandido.", "kind" => "human_declaration"}
      },
      %GameEvent{type: :narration, actor: "dm", payload: %{"text" => "El bandido cae."}}
    ]

    assert [
             %{"role" => "user", "content" => intent},
             %{"role" => "assistant", "content" => result}
           ] = History.from_events(events) |> ModelMessages.project()

    assert intent == "[Thane declara]: \"Ataco al bandido.\""
    assert result == "[DM]: El bandido cae."
    imported = History.import_events(events) |> ModelMessages.project()
    assert hd(imported)["content"] == intent
    assert List.last(imported)["content"] =~ "CRÓNICA REGISTRADA"
  end

  test "an older literal declaration is unabridged and private declarations stay private" do
    text =
      String.duplicate("Declaro mis palabras con cuidado. ", 12) <> "«Esta es mi cita exacta»."

    voice = %GameEvent{
      type: :narration,
      actor: "Thane",
      payload: %{"text" => text, "kind" => "human_declaration"}
    }

    private = %{
      voice
      | visible_to: "dm",
        payload: %{"text" => "Secreto", "kind" => "human_declaration"}
    }

    later =
      for n <- 1..15,
          do: %GameEvent{
            type: :narration,
            actor: "PC#{n}",
            payload: %{"text" => "Una respuesta."}
          }

    history = History.from_events([voice, private | later]) |> ModelMessages.project()
    assert hd(history)["content"] == "[Thane declara]: \"#{text}\""
    refute inspect(history) =~ "Secreto"
  end
end
