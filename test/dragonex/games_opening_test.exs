defmodule Dragonex.GamesOpeningTest do
  use ExUnit.Case, async: false

  alias Dragonex.{Archetypes, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp opening(scene) do
    {:ok, game} =
      Games.create_game(title: "Apertura", scene: scene, roster: [{Archetypes.fighter(), :human}])

    Enum.find(Games.list_events(game.id), &(&1.type == :narration)).payload["text"]
  end

  # 19451/2 printed «…sacos de harina..».
  test "the opening closes the scene's sentence exactly once" do
    assert opening("Dos ratas merodean entre los sacos de harina.") ==
             "La escena está preparada: Dos ratas merodean entre los sacos de harina."

    assert opening("¿Quién llama a la puerta?  ") ==
             "La escena está preparada: ¿Quién llama a la puerta?"

    assert opening("Una taberna") == "La escena está preparada: Una taberna."
  end
end
