defmodule Dragonex.HistoryCompressionUTF8Test do
  use ExUnit.Case, async: true
  alias Dragonex.History
  alias Dragonex.Games.GameEvent
  alias Dragonex.Test.ModelMessages

  defp old_history(body) do
    first = %GameEvent{
      type: :narration,
      actor: "Mara de la Bruma",
      seq: 1,
      payload: %{"text" => body}
    }

    recent =
      for i <- 1..12 do
        %GameEvent{
          type: :narration,
          actor: if(rem(i, 2) == 0, do: "Vex", else: "dm"),
          seq: i + 1,
          payload: %{"text" => "La lámpara sigue encendida: intervención #{i}."}
        }
      end

    History.from_events([first | recent]) |> ModelMessages.project()
  end

  test "compressing the real menu question keeps the provider payload valid after twelve newer voices" do
    raw =
      File.read!(
        Path.expand("../fixtures/narration/human_history_compression_question.txt", __DIR__)
      )
      |> String.trim()

    wire = old_history(raw)
    assert Enum.all?(wire, &String.valid?(&1["content"]))
    encoded = Jason.encode!(wire)
    assert Jason.decode!(encoded) == wire
    first = hd(wire)["content"]
    assert first =~ "[Mara de la Bruma]:"
    assert first =~ "¿Qué plato sirves hoy"
    assert String.ends_with?(first, " …")
    refute first =~ "cuenco de barro."

    for i <- 1..12 do
      assert Enum.at(wire, i)["content"] =~ "intervención #{i}."
    end
  end

  test "opening Spanish punctuation and multibyte spaces are preserved until a real sentence ending" do
    prefix = String.duplicate("paso ", 18)

    for sentence <- [
          "¿Qué senda continúa?",
          "¡La brújula señala el río!",
          "El sendero\u00a0continúa hasta allí."
        ] do
      body = prefix <> sentence <> String.duplicate(" Después siguen más palabras", 12)
      wire = old_history(body)
      assert hd(wire)["content"] == "[Mara de la Bruma]: " <> prefix <> sentence <> " …"
      assert Jason.decode!(Jason.encode!(wire)) == wire
    end
  end
end
