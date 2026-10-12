defmodule Dragonex.HistoryTest do
  @moduledoc """
  Covers the shared-history reconstruction (`Dragonex.History.from_events/1`),
  focused on the two fixes that killed the partida's "temporal loop":

    1. `coalesce_assistant_runs` must NOT merge narrations from DIFFERENT actors
       (it used to fuse a DM line and a PC line into one assistant blob, which
       made the model lose track of who said what and re-narrate past events).
    2. `@recent_narrations_kept` (now 12) keeps enough horizon for multi-agent
       continuity; older narration is truncated to ~180 chars.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Games.GameEvent
  alias Dragonex.History
  alias ExAgent.Message.Response

  defp narration(actor, text, seq),
    do: %GameEvent{type: :narration, actor: actor, payload: %{"text" => text}, seq: seq}

  defp turn(actor, round, phase, seq),
    do: %GameEvent{
      type: :turn,
      actor: actor,
      payload: %{"kind" => "start", "round" => round, "phase" => phase},
      seq: seq
    }

  defp responses(messages), do: Enum.filter(messages, &match?(%Response{}, &1))

  defp text_of(%Response{parts: [%ExAgent.Message.Part.Text{content: c}]}), do: c

  test "agent history preserves the actual weapon penalty and explains a zero damage minimum" do
    event = %GameEvent{
      type: :dice,
      actor: "Arden",
      seq: 1,
      payload: %{
        "kind" => "damage",
        "who" => "Arden",
        "reason" => "daño del arma",
        "dice" => [[4, 1]],
        "total" => 0,
        "raw_total" => -1
      }
    }

    context = inspect(History.from_events([event]), limit: :infinity)
    assert context =~ "d4:1 -2 = 0 (mínimo 0)"
    refute context =~ "d4:1 -1 = 0"
  end

  test "narrations from DIFFERENT actors stay as separate assistant turns" do
    events = [
      turn("dm", 1, :exploration, 1),
      narration("dm", "El goblin surge de las sombras.", 2),
      turn("Thane", 1, :exploration, 3),
      narration("Thane", "Desenfundo mi espada.", 4),
      turn("Lyra", 1, :exploration, 5),
      narration("Lyra", "Preparo un firebolt.", 6)
    ]

    resps = events |> History.from_events() |> responses()

    # Three distinct narrations -> three separate Response messages, NOT fused.
    assert length(resps) == 3
    assert resps |> Enum.at(0) |> text_of() =~ "[DM]: El goblin"
    assert resps |> Enum.at(1) |> text_of() =~ "[Thane]: Desenfundo"
    assert resps |> Enum.at(2) |> text_of() =~ "[Lyra]: Preparo"
  end

  test "narrations from the SAME actor DO coalesce (mid-beat + final)" do
    # Two DM narrations with no other actor between them — e.g. the Events
    # capability publishing a declaration and then the wrap-up. These merge.
    events = [
      narration("dm", "El goblin ruge.", 1),
      narration("dm", "Carga contra Thane.", 2)
    ]

    resps = events |> History.from_events() |> responses()

    assert length(resps) == 1
    combined = text_of(hd(resps))
    assert combined =~ "El goblin ruge."
    assert combined =~ "Carga contra Thane."
  end

  test "a DM line followed by a PC line then another DM line: 3 turns, not 1" do
    events = [
      narration("dm", "Escena uno.", 1),
      narration("Thane", "Actúo.", 2),
      narration("dm", "Escena dos.", 3)
    ]

    resps = events |> History.from_events() |> responses()

    # DM, then Thane, then DM again — three separate turns. The earlier bug
    # would have fused all three into a single assistant message.
    assert length(resps) == 3
    assert text_of(Enum.at(resps, 0)) =~ "[DM]: Escena uno"
    assert text_of(Enum.at(resps, 1)) =~ "[Thane]: Actúo"
    assert text_of(Enum.at(resps, 2)) =~ "[DM]: Escena dos"
  end

  test "the @recent_narrations_kept most recent narrations are kept verbatim" do
    # Alternate actors so consecutive narrations DON'T coalesce — we need 15
    # separate Response messages to exercise the compression path. (15 narrations
    # by the SAME actor would correctly merge into one, which hides truncation.)
    events =
      for i <- 1..15 do
        actor = if rem(i, 2) == 0, do: "Thane", else: "dm"
        # Long enough that truncation kicks in (well over 180 chars).
        body = String.duplicate("palabra ", 40) <> "marca #{i}."
        narration(actor, body, i)
      end

    resps = events |> History.from_events() |> responses()

    assert length(resps) == 15

    # The 3 oldest are truncated (their trailing unique marker is lost).
    refute text_of(Enum.at(resps, 0)) =~ "marca 1."
    refute text_of(Enum.at(resps, 2)) =~ "marca 3."

    # The last 12 are verbatim — their unique markers survive.
    for i <- 4..15 do
      assert text_of(Enum.at(resps, i - 1)) =~ "marca #{i}."
    end
  end

  test "actor is extracted correctly with or without a turn header" do
    # Validates the narrator-attribution helper that coalesce relies on.
    events_with_header = [
      turn("Vex", 2, :combat, 1),
      narration("Vex", "Disparo.", 2)
    ]

    events_without_header = [
      narration("Thane", "Cargo.", 1)
    ]

    [r1] = events_with_header |> History.from_events() |> responses()
    [r2] = events_without_header |> History.from_events() |> responses()

    # Header case: "[R2 · combate · Turno de Vex] [Vex]: Disparo."
    assert text_of(r1) =~ "[Vex]: Disparo."
    # No header case: "[Thane]: Cargo."
    assert text_of(r2) =~ "[Thane]: Cargo."
  end
end
