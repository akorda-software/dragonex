defmodule Dragonex.DMPuppetPCTest do
  @moduledoc """
  Bug #4 — the DM occasionally narrates a PC acting on its behalf ("*Lyra
  desenvaina y ataca*"), which rule 14 forbids. The prompt alone leaks through.

   Persist path (`Text.strip_puppet_clauses/2`, D29) drops subject-initial
   "<pc-name> <action-verb>" clauses. The detector/nudge still covers mid-clause
   leaks the strip leaves in place. Passive state ("Lyra cae herida") is kept.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Dragonex.{Archetypes, Games, Game}
  alias Dragonex.Game.Guardrails
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragonex.Repo, {:shared, self()})
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

  test "subject-initial puppet clauses are stripped before persist" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    script = [
      "Lyra ataca el aire con su daga, probando el peso del arma. La cripta espera.",
      "Un viento frío recorre la cripta."
    ]

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Dragonex.Game, {game.id, [model: %Test{script: script}, roller: fn _ -> 10 end]}}
      )

    assert :ok ==
             Game.await(
               pid,
               fn _s -> dm_narration_count(game.id) >= 1 end,
               10_000
             )

    texts =
      game.id
      |> Games.list_events()
      |> Enum.filter(&(&1.type == :narration and &1.actor == "dm"))
      |> Enum.map(&(&1.payload["text"] || ""))
      |> Enum.reject(&String.starts_with?(&1, "La escena está preparada"))

    joined = Enum.join(texts, " ")
    refute joined =~ ~r/Lyra ataca/i
    assert joined =~ "La cripta espera"
  end

  test "mid-clause puppet leak still triggers a rule-14 reminder" do
    {:ok, game} =
      Games.create_game(
        title: "puppet",
        scene: "una cripta silenciosa",
        roster: [{Archetypes.wizard(), :ai}]
      )

    # Does not start with the PC name, so the structural strip keeps it;
    # the looser detector still nudges the next beat.
    script = [
      "Entre las sombras, junto a un pilar, Lyra ataca el aire.",
      "La cripta guarda silencio."
    ]

    log =
      capture_log(fn ->
        pid =
          ExUnit.Callbacks.start_supervised!(
            {Dragonex.Game, {game.id, [model: %Test{script: script}, roller: fn _ -> 10 end]}}
          )

        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> dm_narration_count(game.id) >= 2 end,
                   10_000
                 )
      end)

    assert log =~ "reinforcing rule 14"
  end

  test "detector catches playtest-style puppet leaks (pure)" do
    pcs = ["Lyra", "Vex", "Rhogar"]

    assert Guardrails.dm_narration_puppets_pc?(
             "Lyra, sonriendo, conjura firebolt contra el maniquí.",
             pcs
           )

    assert Guardrails.dm_narration_puppets_pc?(
             "Vex ya tensa su arco corto, mirando de reojo.",
             pcs
           )

    assert Guardrails.dm_narration_puppets_pc?(
             "Vex aprovecha el descuido del sabueso y dispara desde el flanco.",
             pcs
           )

    refute Guardrails.dm_narration_puppets_pc?(
             "Lyra está herida junto a la valla.",
             pcs
           )

    refute Guardrails.dm_narration_puppets_pc?(
             "El sabueso se abalanza contra Rhogar.",
             pcs
           )
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
          ExUnit.Callbacks.start_supervised!(
            {Dragonex.Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

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
