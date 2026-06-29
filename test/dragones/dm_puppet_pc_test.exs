defmodule Dragones.DMPuppetPCTest do
  @moduledoc """
  Bug #4 — the DM occasionally narrates a PC acting on its behalf ("*Lyra
  desenvaina y ataca*"), which rule 14 forbids. The prompt alone leaks through.

  Fix: `Dragones.Game.with_dm_no_puppet_nudge/3` inspects the DM's last narration
  for a "<pc-name> <action-verb>" pattern and, when it matches, stitches a
  rule-14 reminder onto the DM's next instruction. No scrubbing — that risks
  mangling legitimate narration ("Lyra cae herida" is fine); a targeted reminder
  corrects course on the next beat.
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

  # Count :narration events produced by the DM, EXCLUDING the "La escena está
  # preparada" opening line (which isn't a model beat). The rule-14 nudge lands
  # on the DM beat AFTER a puppeteering narration, so we need at least two real
  # model narrations to observe it.
  defp dm_narration_count(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.count(fn e ->
      e.type == :narration and e.actor == "dm" and
        not String.starts_with?(e.payload["text"] || "", "La escena está preparada")
    end)
  end

  test "the DM narrating a PC acting triggers a rule-14 reminder" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    # The DM's first beat puppeteers Lyra (an action verb right after her name);
    # the second beat is benign. The reminder should land on the SECOND DM turn.
    script = [
      "Lyra ataca el aire con su daga, probando el peso del arma.",
      "La cripta guarda silencio."
    ]

    model = %Test{script: script}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: model, roller: fn _ -> 10 end]}})

        # Wait for at least two DM narrations — the second one runs WITH the
        # rule-14 nudge stitched onto its instruction.
        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> dm_narration_count(game.id) >= 2 end,
                   10_000
                 )
      end)

    assert log =~ "reinforcing rule 14",
           "the DM narrating a PC acting should trigger the rule-14 reminder on the next beat"
  end

  test "narration that only describes the world does NOT trip the detector" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    # Legitimate world narration mentioning a PC by name (no action verb) — the
    # detector must not fire and slander the DM.
    script = [
      "La luz temblorosa revela glifos junto a donde está Lyra.",
      "Un viento frío recorre la cripta."
    ]

    model = %Test{script: script}

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: model, roller: fn _ -> 10 end]}})

        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> dm_narration_count(game.id) >= 2 end,
                   10_000
                 )
      end)

    refute log =~ "reinforcing rule 14",
           "world narration that merely mentions a PC must not trip the puppet detector"
  end
end
