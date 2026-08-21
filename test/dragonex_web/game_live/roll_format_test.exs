defmodule DragonexWeb.GameLive.RollFormatTest do
  @moduledoc """
  The dice-roll formatters are pure presentation extracted from the chat timeline
  and the dice modal. Lock the exact strings so a future tweak to the outcome
  table or the dice assembly can't silently drift.
  """

  use ExUnit.Case, async: true

  alias DragonexWeb.GameLive.RollFormat, as: RF

  describe "format_line/1 (chat inline line)" do
    test "reason + dice + positive mod + total + against + outcome" do
      line =
        RF.format_line(%{
          "reason" => "ataque",
          "dice" => [[20, 5]],
          "total" => 9,
          "against" => ["ac", 15],
          "outcome" => "hit"
        })

      assert line == "ataque d20:5 +4 = 9 vs CA 15 → ¡ACIERTO!"
    end

    test "negative mod is shown with a minus, dc against, miss outcome" do
      line =
        RF.format_line(%{
          "reason" => "salvación",
          "dice" => [[20, 3]],
          "total" => 1,
          "against" => ["dc", 12],
          "outcome" => "failure"
        })

      assert line == "salvación d20:3 -2 = 1 vs DC 12 → fallo"
    end

    test "zero mod is omitted, accepts atom keys and multi-dice" do
      line =
        RF.format_line(%{
          reason: "daño",
          dice: [[8, 4], [6, 2]],
          total: 6,
          outcome: :hit
        })

      # dice_sum = 4 + 2 = 6; mod = 0 → omitted.
      assert line == "daño d8:4 d6:2 = 6 → ¡ACIERTO!"
    end

    test "no total, no against, no outcome → bare reason + dice" do
      assert RF.format_line(%{"reason" => "tirada", "dice" => [[6, 3]]}) == "tirada d6:3"
    end

    test "defaults the reason to \"tirada\" when missing" do
      assert RF.format_line(%{"dice" => [[4, 2]]}) == "tirada d4:2"
    end
  end

  describe "format_dice/1 (modal dice summary)" do
    test "dice + mod + total, no reason, no outcome" do
      assert RF.format_dice(%{"dice" => [[20, 5]], "total" => 9}) == "d20:5 +4 = 9"
    end

    test "negative mod" do
      assert RF.format_dice(%{dice: [[20, 3]], total: 1}) == "d20:3 -2 = 1"
    end

    test "no total → no mod, no total shown" do
      assert RF.format_dice(%{"dice" => [[8, 4], [8, 2]]}) == "d8:4 d8:2"
    end
  end

  describe "format_against/1 and format_against_spaced/1" do
    test "compact (no leading space)" do
      assert RF.format_against(["ac", 15]) == "vs CA 15"
      assert RF.format_against(["dc", 12]) == "vs DC 12"
      assert RF.format_against({:ac, 15}) == "vs CA 15"
      assert RF.format_against({:dc, 12}) == "vs DC 12"
      assert RF.format_against(nil) == ""
    end

    test "spaced (leading space, for the modal card)" do
      assert RF.format_against_spaced(["ac", 15]) == " vs CA 15"
      assert RF.format_against_spaced(nil) == ""
    end
  end

  describe "outcome table" do
    @outcome_expectations %{
      hit: {"→ ¡ACIERTO!", "¡Acierto!", "dg-win"},
      crit: {"→ ¡CRÍTICO!", "¡Crítico!", "dg-win"},
      miss: {"→ fallo", "Fallo", "dg-lose"},
      success: {"→ éxito", "Éxito", "dg-win"},
      failure: {"→ fallo", "Fallo", "dg-lose"},
      revive: {"→ ¡revive!", "¡Revive!", "dg-win"},
      crit_fail: {"→ ¡PIFIA!", "¡Pifia! (2 fallos)", "dg-lose"}
    }

    test "every outcome resolves to the right (line, label, css)" do
      for {outcome, {line, label, css}} <- @outcome_expectations do
        assert RF.outcome_line(outcome) == line, "outcome_line #{outcome}"
        assert RF.outcome_label(outcome) == label, "outcome_label #{outcome}"
        assert RF.outcome_css(outcome) == css, "outcome_css #{outcome}"
      end
    end

    test "string outcomes normalize to the same value as their atom form" do
      for {atom, {line, label, css}} <- @outcome_expectations do
        str = Atom.to_string(atom)

        assert RF.outcome_line(str) == line
        assert RF.outcome_label(str) == label
        assert RF.outcome_css(str) == css
      end
    end

    test "unknown outcome → empty line/label, neutral css" do
      assert RF.outcome_line(:nope) == ""
      assert RF.outcome_label("???") == ""
      assert RF.outcome_css(nil) == "dg-neutral"
    end

    test "normalize_outcome/1" do
      assert RF.normalize_outcome(:hit) == :hit
      assert RF.normalize_outcome("crit") == :crit
      assert RF.normalize_outcome(7) == nil
    end
  end
end
