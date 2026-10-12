defmodule Dragonex.GameEnglishTableTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, Monsters}
  alias Dragonex.Test.ModelMessages

  # D236: a table created in English produces English everywhere the app
  # writes: the DM's instructions, tool feedback, roll reasons and notes.
  @spanish ~r/[áéíóúñ¿¡]|\b(el|la|los|las|del|que|con|para|una|turno|daño|tirada|conjura|ataque|partida|escena|iniciativa|combate)\b/iu

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp spanish_in(texts), do: Enum.filter(texts, &Regex.match?(@spanish, &1))

  test "an English game speaks English to the model and on the table" do
    {:ok, game} =
      Games.create_game(
        title: "The mill",
        scene: "Two giant rats lurk among the flour sacks.",
        locale: "en",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(name: "g1"), :ai}]
      )

    assert game.locale == "en"
    owner = self()

    model = %ExAgent.Models.Test{
      script: [
        tool_calls([call("roll_initiative", %{})]),
        tool_calls([
          call("make_attack", %{
            "attacker" => "g1",
            "target" => "Thane",
            "weapon" => "scimitar",
            "mode" => "normal"
          })
        ]),
        fn messages, _ ->
          send(owner, {:dm_context, ModelMessages.project(messages)})
          narration("The goblin snarls and slashes at Thane.")
        end,
        narration("The goblin circles, looking for an opening.")
      ]
    }

    roller = fn
      20 -> 15
      _ -> 1
    end

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: roller]}})
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 8_000)
    assert :ok = Game.pause(pid)

    assert_receive {:dm_context, context}
    [system | rest] = context
    system_text = inspect(system, limit: :infinity)
    assert system_text =~ "English"
    refute system_text =~ "castellano"

    # What the engine told the model after its tools ran.
    tool_returns =
      for %{"role" => "tool", "content" => content} <- rest, do: content

    assert tool_returns != []
    assert spanish_in(tool_returns) == []

    events = Games.list_events(game.id)

    table_texts =
      for e <- events,
          e.type in [:system, :dice],
          text = e.payload["note"] || e.payload["reason"],
          do: text

    assert Enum.any?(table_texts, &(&1 =~ "initiative"))
    assert spanish_in(table_texts) == []
  end
end
