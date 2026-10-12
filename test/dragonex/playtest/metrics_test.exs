defmodule Dragonex.Playtest.MetricsTest do
  use ExUnit.Case, async: true

  alias Dragonex.Playtest.Metrics

  @t0 ~N[2026-10-12 10:00:00]

  defp ev(seq, at, type, actor, payload),
    do: %{
      seq: seq,
      inserted_at: NaiveDateTime.add(@t0, at),
      type: type,
      actor: actor,
      payload: payload
    }

  defp start(seq, at, actor, phase),
    do: ev(seq, at, :turn, actor, %{"kind" => "start", "phase" => phase})

  defp handoff(seq, at, to), do: ev(seq, at, :system, "turnmaster", %{"to" => to})

  # Thane (humano) ataca con tirada; el DM responde; Lyra (IA) actúa; vuelve Thane.
  defp combat_round do
    [
      start(1, 0, "Thane", "combat"),
      ev(2, 0, :action, "Thane", %{"text" => "Ataco a la rata."}),
      ev(3, 1, :dice, "Thane", %{"kind" => "attack"}),
      handoff(4, 3, "giant rat"),
      start(5, 3, "dm", "combat"),
      ev(6, 10, :narration, "dm", %{"text" => "La rata muerde."}),
      handoff(7, 11, "Lyra"),
      start(8, 11, "Lyra", "combat"),
      ev(9, 15, :narration, "Lyra", %{"text" => "Lanzo dardos."}),
      handoff(10, 16, "Thane")
    ]
  end

  test "cuenta turnos por tipo de actor y mide la ida y vuelta humana" do
    m = Metrics.analyze(combat_round(), ["Thane"])

    assert m.turns == %{dm: 1, ai_pc: 1, human: 1}
    assert m.round_trip.samples == [16]
    assert m.ai_turn_seconds.dm.samples == [8]
    assert m.ai_turn_seconds.ai_pc.samples == [5]
    assert m.failures == 0
    assert m.combat_actions_without_dice == []
  end

  test "señala una declaración de combate sin tirada propia" do
    events =
      combat_round()
      |> Enum.reject(&(&1.seq == 3))

    assert [%{seq: 2, actor: "Thane", text: "Ataco a la rata."}] =
             Metrics.analyze(events, ["Thane"]).combat_actions_without_dice
  end

  test "las tiradas de otro actor no cuentan como tirada del humano" do
    events =
      combat_round()
      |> Enum.map(fn
        %{seq: 3} = e -> %{e | actor: "dm"}
        e -> e
      end)

    assert [%{seq: 2}] = Metrics.analyze(events, ["Thane"]).combat_actions_without_dice
  end

  test "fuera de combate no se exigen tiradas" do
    events = [
      start(1, 0, "Thane", "exploration"),
      ev(2, 0, :action, "Thane", %{"text" => "Hablo con Mira."})
    ]

    assert Metrics.analyze(events, ["Thane"]).combat_actions_without_dice == []
  end

  test "cuenta fallos por kind o por el texto de partidas anteriores, y la tasa por turno IA" do
    events =
      combat_round() ++
        [
          ev(11, 20, :system, "system", %{"kind" => "turn_failed", "note" => "x"}),
          ev(12, 21, :system, "system", %{"note" => "el turno falló: :timeout"}),
          ev(13, 22, :system, "system", %{"note" => "the turn failed: :timeout"}),
          ev(14, 23, :system, "system", %{"kind" => "turn_retained"}),
          ev(15, 24, :system, "system", %{"kind" => "turn_skipped"}),
          ev(16, 25, :system, "turnmaster", %{"kind" => "turnmaster_fallback", "to" => nil})
        ]

    m = Metrics.analyze(events, ["Thane"])

    assert m.failures == 3
    assert m.retained == 1
    assert m.skipped == 1
    assert m.tm_fallbacks == 1
    assert m.failure_rate == 1.5
  end

  test "excluye de la ida y vuelta los tramos con pausa por fallo" do
    events =
      Enum.map(combat_round(), fn
        %{seq: 6} = e ->
          %{e | type: :system, actor: "system", payload: %{"kind" => "turn_retained"}}

        e ->
          e
      end)

    m = Metrics.analyze(events, ["Thane"])
    assert m.round_trip.count == 0
    assert m.ai_turn_seconds.dm.count == 0
    assert m.ai_turn_seconds.ai_pc.count == 1
  end

  test "merge combina contadores y muestras, y format lo resume" do
    a = Metrics.analyze(combat_round(), ["Thane"])
    m = Metrics.merge([a, a])

    assert m.turns == %{dm: 2, ai_pc: 2, human: 2}
    assert m.round_trip.samples == [16, 16]
    assert Metrics.format(m) =~ "ida y vuelta humana (s): n=2 p50 16"
  end

  test "percentiles por rango más cercano" do
    s = Metrics.stats(Enum.to_list(1..10))
    assert {s.p50, s.p90, s.max} == {5, 9, 10}
    assert Metrics.stats([]).count == 0
  end
end
