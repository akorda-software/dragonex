defmodule Dragonex.HistorySpeechEchoTest do
  use ExUnit.Case, async: true
  alias Dragonex.{History, Games.GameEvent, Narration}
  alias Dragonex.Test.ModelMessages

  defp event(seq, type, actor, payload),
    do: %GameEvent{
      seq: seq,
      type: type,
      actor: actor,
      payload: Map.put_new(payload, "turn_id", "t1")
    }

  defp contents(events),
    do: events |> History.from_events() |> ModelMessages.project() |> Enum.map(& &1["content"])

  test "the model rereads the human words and the DM's copied closure once" do
    words = "Ataco al bandido con mi espada larga."
    closure = "El bandido se dobla sobre la mesa y ya no se levanta."

    events = [
      event(1, :action, "Thane", %{"text" => words}),
      event(2, :narration, "Thane", %{
        "text" => words,
        "kind" => "human_declaration",
        "complete" => true
      }),
      event(3, :narration, "dm", %{"text" => closure, "turn_id" => "t2", "complete" => false}),
      event(4, :narration, "dm", %{"text" => closure, "turn_id" => "t2", "complete" => true})
    ]

    history = contents(events)
    assert Enum.count(history, &(&1 =~ words)) == 1
    assert Enum.count(history, &(&1 =~ closure)) == 1
    assert hd(history) == "[Thane declara]: \"#{words}\""
  end

  test "a continuation after dice keeps both DM lines" do
    events = [
      event(1, :narration, "dm", %{
        "text" => "El bandido lanza un tajo bajo contra Thane.",
        "complete" => false
      }),
      event(2, :narration, "dm", %{
        "text" => "La cimitarra abre un corte en el costado del guerrero.",
        "complete" => true
      })
    ]

    history = inspect(contents(events))
    assert history =~ "tajo bajo"
    assert history =~ "abre un corte"
  end

  test "the closure protocol asks final_result not to repeat narrate" do
    assert Narration.Contract.instruction() =~ "sin copiarlo, citarlo de nuevo ni parafrasearlo"
  end
end
