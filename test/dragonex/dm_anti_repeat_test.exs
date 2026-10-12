defmodule Dragonex.DMAntiRepeatTest do
  @moduledoc """
  Bug — calcified narration. The DM reuses the exact same line ("se desvanece en
  una nube de humo sulfúrico" x N) turn after turn, reading like a broken record.

  Fix: `Dragonex.Game.with_dm_anti_repeat/2` compares the DM's last two
  narrations (Jaccard >= 0.7) and, on a near-duplicate, stitches a variety nudge
  onto the next DM instruction.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Games, Game}
  alias ExAgent.Models.Test
  alias ExAgent.Server

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp dm_narration_count(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.count(fn e ->
      e.type == :narration and e.actor == "dm" and
        not String.starts_with?(e.payload["text"] || "", "La escena está preparada")
    end)
  end

  test "the DM repeating a line triggers the variety nudge" do
    {:ok, game} =
      Games.create_game(
        title: "repeat",
        scene: "una cripta",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # The DM narrates the SAME death description twice in a row.
    model = %Dragonex.Test.Narrator{
      text: "El no-muerto se desvanece en una nube de humo sulfúrico."
    }

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        # The nudge lands on the THIRD DM turn (comparing the previous two);
        # wait for at least three DM narrations so the log captures it.
        assert :ok ==
                 Game.await(pid, fn _s -> dm_narration_count(game.id) >= 3 end, 10_000)
      end)

    assert log =~ "DM repeating narration",
           "a near-duplicate DM line should trigger the anti-repeat nudge"
  end

  test "varied DM narration does NOT trip the anti-repeat" do
    {:ok, game} =
      Games.create_game(
        title: "repeat",
        scene: "una cripta",
        roster: [{Archetypes.fighter(), :ai}]
      )

    script = [
      "Las antorchas parpadean al pasar el viento frío.",
      "Un crujido lejano resuena entre la piedra mojada.",
      "Gotas de agua golpean el suelo de la cripta."
    ]

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, nil, before.round, :paused)
    parent = self()

    last = fn _, _ ->
      send(parent, {:varied_dm_ready, self()})
      receive do: (:narrate -> narration(List.last(script)))
    end

    model = %Test{script: Enum.map(Enum.take(script, 2), &narration/1) ++ [last]}

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        :ok =
          Server.set_model(:sys.get_state(pid).pc_agents["Thane"], %Dragonex.Test.Narrator{
            text: "Observo la cripta."
          })

        assert :ok == Game.resume(pid)
        assert_receive {:varied_dm_ready, request}, 2_000

        try do
          assert Game.current(pid) == "dm"
          assert :ok == Game.pause(pid)
        after
          send(request, :narrate)
        end

        assert :ok == Game.await(pid, &(&1.status == :paused and :sys.get_state(pid).busy == nil))

        narration =
          for event <- Games.list_events(game.id),
              event.type == :narration and event.actor == "dm" and
                not String.starts_with?(event.payload["text"] || "", "La escena está preparada"),
              do: event.payload["text"]

        assert narration == script
        assert Game.world(pid) == before
        assert Games.load_world(Games.get_game(game.id)) == before
      end)

    refute log =~ "DM repeating narration",
           "distinct DM lines must not trip the anti-repeat detector"

    refute log =~ "model_request_failed"
  end

  test "the DM drifting into English triggers the Spanish nudge" do
    {:ok, game} =
      Games.create_game(
        title: "lang",
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # An English narration (DeepSeek sometimes drifts) — has plenty of the
    # clearly-English function words the detector counts.
    model = %Dragonex.Test.Narrator{
      text: "The sun has climbed above the hills and the wind smells of dust."
    }

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        assert :ok ==
                 Game.await(pid, fn _s -> dm_narration_count(game.id) >= 2 end, 10_000)
      end)

    assert log =~ "drifted into English",
           "an English DM narration should trigger the Spanish-enforcement nudge"
  end
end
