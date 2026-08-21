defmodule Dragonex.PCAntiLoopTest do
  @moduledoc """
  Bug #3 — ANTIBUCLE. A bot re-declaring the same non-action ("¿subimos al
  círculo?" x N, "voy a calentar el brazo" x N) stalled the partida. The system
  prompt already forbids it; prompts alone weren't enough.

  Fix: `Dragonex.Game.with_pc_anti_loop/3` compares a bot's last two narrations
  (Jaccard over word sets, threshold 0.75) and, on a near-duplicate, stitches a
  hard anti-loop nudge onto the instruction forcing a DIFFERENT concrete action.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Dragonex.{Archetypes, Games, Game}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragonex.Repo, {:shared, self()})
    :ok
  end

  # Count :narration events produced by `actor`.
  defp narration_count(game_id, actor) do
    game_id
    |> Games.list_events()
    |> Enum.count(fn e -> e.type == :narration and e.actor == actor end)
  end

  test "a bot repeating itself triggers the anti-loop nudge" do
    {:ok, game} =
      Games.create_game(
        title: "loop",
        scene: "una sala con varias puertas",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # The model always replies with the SAME line — the classic loop where a bot
    # re-declares an intention without ever acting on it.
    model = %Test{label: "¿Empezamos a subir al círculo superior?"}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragonex.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        # Wait until the fighter has produced at least 3 narrations — by the 3rd
        # turn its previous two lines are near-identical, so the engine injects
        # the anti-loop nudge before that beat runs.
        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> narration_count(game.id, "Thane") >= 3 end,
                   10_000
                 )
      end)

    assert log =~ "anti-loop nudge",
           "the anti-loop nudge should fire once a bot repeats its own line"
  end

  test "a bot that varies its lines does NOT trip the anti-loop" do
    {:ok, game} =
      Games.create_game(
        title: "loop",
        scene: "una sala con varias puertas",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # Distinct lines each turn — no repetition, no nudge.
    script = [
      "Inspecciono las puertas del norte.",
      "Camin hacia el altar y lo examino.",
      "Llamo al grupo para que me siga."
    ]

    model = %Test{script: script}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragonex.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> narration_count(game.id, "Thane") >= 3 end,
                   10_000
                 )
      end)

    refute log =~ "anti-loop nudge",
           "distinct lines must not trip the anti-loop detector"
  end
end
