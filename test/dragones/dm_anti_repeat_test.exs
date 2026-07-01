defmodule Dragones.DMAntiRepeatTest do
  @moduledoc """
  Bug — calcified narration. The DM reuses the exact same line ("se desvanece en
  una nube de humo sulfúrico" x N) turn after turn, reading like a broken record.

  Fix: `Dragones.Game.with_dm_anti_repeat/2` compares the DM's last two
  narrations (Jaccard >= 0.7) and, on a near-duplicate, stitches a variety nudge
  onto the next DM instruction.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Dragones.{Archetypes, Games, Game}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})
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
    model = %Test{label: "El no-muerto se desvanece en una nube de humo sulfúrico."}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragones.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
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
      "Un crujido lejano resuena entre la piedra mojada."
    ]

    model = %Test{script: script}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragones.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        assert :ok ==
                 Game.await(pid, fn _s -> dm_narration_count(game.id) >= 3 end, 10_000)
      end)

    refute log =~ "DM repeating narration",
           "distinct DM lines must not trip the anti-repeat detector"
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
    model = %Test{label: "The sun has climbed above the hills and the wind smells of dust."}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragones.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        assert :ok ==
                 Game.await(pid, fn _s -> dm_narration_count(game.id) >= 2 end, 10_000)
      end)

    assert log =~ "drifted into English",
           "an English DM narration should trigger the Spanish-enforcement nudge"
  end
end
