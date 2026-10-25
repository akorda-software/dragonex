defmodule Dragonex.Playtest.Metrics do
  @moduledoc """
  Métricas de calidad de una partida a partir de su timeline (`game_events`).

  Puro: recibe los eventos y los nombres de los participantes humanos, sin tocar
  la DB. Sirve igual para partidas antiguas que para las del arnés de playtest
  (`mix dragonex.playtest`), de modo que las correcciones se priorizan por
  frecuencia medida y no caso a caso.

  Mide:

    * **turnos** por tipo de actor (DM, PC IA, humano);
    * **fallos**: notas `turn_failed` (o su texto en partidas anteriores),
      pausas `turn_retained`, omisiones `turn_skipped` y relevos de emergencia
      del TurnMaster (`turnmaster_fallback`);
    * **ida y vuelta**: segundos desde que un humano declara hasta que vuelve a
      tener la palabra, sin contar los tramos con una pausa por fallo (incluyen
      la espera del usuario). Solo cuenta retornos con destinatario explícito
      anteriores a su siguiente declaración; un fallback antiguo sin destino
      cierra la búsqueda porque no demuestra quién recuperó el turno;
    * **duración de turnos IA**: desde su `turn start` hasta el siguiente relevo;
    * **acciones de combate sin tirada**: declaraciones humanas en combate sin
      ningún dado de ese actor dentro del turno. No todas son errores (esquivar,
      hablar), por eso se listan para revisarlas.

  Las marcas de tiempo de `game_events` tienen resolución de segundos.
  """

  @failure_prefixes ["el turno falló", "the turn failed"]

  @type stats :: %{count: non_neg_integer(), p50: number(), p90: number(), max: number()}

  @doc "Analiza los eventos (en orden de `seq`) de una partida."
  @spec analyze([map()], [String.t()]) :: map()
  def analyze(events, humans) do
    events = Enum.sort_by(events, & &1.seq)
    humans = MapSet.new(humans)
    starts = Enum.filter(events, &turn_start?/1)

    turns =
      Enum.frequencies_by(starts, fn e -> actor_kind(e.actor, humans) end)
      |> then(&Map.merge(%{dm: 0, ai_pc: 0, human: 0}, &1))

    ai_turns = turns.dm + turns.ai_pc
    failures = Enum.count(events, &failure?/1)

    %{
      events: length(events),
      turns: turns,
      failures: failures,
      retained: count_kind(events, "turn_retained"),
      skipped: count_kind(events, "turn_skipped"),
      tm_fallbacks: count_kind(events, "turnmaster_fallback"),
      failure_rate: if(ai_turns > 0, do: failures / ai_turns, else: 0.0),
      round_trip: events |> round_trips(humans) |> stats(),
      ai_turn_seconds: ai_turn_durations(events, humans),
      combat_actions_without_dice: combat_actions_without_dice(events, humans)
    }
  end

  @doc "Agrega los resultados de varias partidas (las listas de segundos se combinan)."
  @spec merge([map()]) :: map()
  def merge(results) do
    sum = fn key -> results |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

    turns =
      Enum.reduce(
        results,
        %{dm: 0, ai_pc: 0, human: 0},
        &Map.merge(&2, &1.turns, fn _, a, b -> a + b end)
      )

    ai_turns = turns.dm + turns.ai_pc
    failures = sum.(:failures)

    %{
      events: sum.(:events),
      turns: turns,
      failures: failures,
      retained: sum.(:retained),
      skipped: sum.(:skipped),
      tm_fallbacks: sum.(:tm_fallbacks),
      failure_rate: if(ai_turns > 0, do: failures / ai_turns, else: 0.0),
      round_trip: results |> Enum.flat_map(& &1.round_trip.samples) |> stats(),
      ai_turn_seconds: %{
        dm: results |> Enum.flat_map(& &1.ai_turn_seconds.dm.samples) |> stats(),
        ai_pc: results |> Enum.flat_map(& &1.ai_turn_seconds.ai_pc.samples) |> stats()
      },
      combat_actions_without_dice: Enum.flat_map(results, & &1.combat_actions_without_dice)
    }
  end

  @doc "Texto legible de un resultado de `analyze/2` o `merge/1`."
  @spec format(map()) :: String.t()
  def format(m) do
    rate = :erlang.float_to_binary(m.failure_rate * 100, decimals: 1)

    without_dice =
      case m.combat_actions_without_dice do
        [] -> "ninguna"
        list -> Enum.map_join(list, "\n", &"    ##{&1.seq} #{&1.actor}: #{&1.text}")
      end

    """
      eventos #{m.events} · turnos DM #{m.turns.dm} / PC IA #{m.turns.ai_pc} / humano #{m.turns.human}
      fallos #{m.failures} (#{rate}% de turnos IA) · pausas #{m.retained} · omitidos #{m.skipped} · relevos de emergencia #{m.tm_fallbacks}
      ida y vuelta humana (s): #{fmt_stats(m.round_trip)}
      turno DM (s): #{fmt_stats(m.ai_turn_seconds.dm)}
      turno PC IA (s): #{fmt_stats(m.ai_turn_seconds.ai_pc)}
      acciones de combate sin tirada: #{without_dice}
    """
  end

  # ------------------------------------------------------------ medidas

  # Humano declara → primer relevo normal o de emergencia que le devuelve la
  # palabra explícitamente. Su siguiente declaración cierra la búsqueda: no
  # atribuir a dos acciones un mismo retorno ni incluir la deliberación entre
  # ellas. Un fallback sin destino también la cierra: no se sabe si devolvió
  # la palabra al humano antes de otra actividad (p. ej. activar autoplay).
  # No se infiere un retorno desde el siguiente turn start, que en humanos
  # se escribe al declarar.
  # Se descarta el tramo si contiene una pausa por fallo.
  defp round_trips(events, humans) do
    indexed = Enum.with_index(events)

    for {%{type: type, actor: actor} = action, i} <- indexed,
        type in [:action, "action"],
        MapSet.member?(humans, actor),
        back = human_return_after(events, i, actor),
        back != nil,
        not Enum.any?(between(events, action.seq, back.seq), &kind?(&1, "turn_retained")) do
      seconds(action.inserted_at, back.inserted_at)
    end
  end

  defp ai_turn_durations(events, humans) do
    durations =
      for {start, i} <- Enum.with_index(events),
          turn_start?(start),
          kind = actor_kind(start.actor, humans),
          kind != :human,
          finish = find_after(events, i, &(handoff?(&1) or turn_start?(&1))),
          finish != nil,
          not Enum.any?(between(events, start.seq, finish.seq), &kind?(&1, "turn_retained")) do
        {kind, seconds(start.inserted_at, finish.inserted_at)}
      end

    %{
      dm: durations |> for_kind(:dm) |> stats(),
      ai_pc: durations |> for_kind(:ai_pc) |> stats()
    }
  end

  defp for_kind(durations, kind), do: for({^kind, s} <- durations, do: s)

  defp combat_actions_without_dice(events, humans) do
    events
    |> Enum.with_index()
    |> Enum.reduce({nil, []}, fn {e, i}, {phase, acc} ->
      cond do
        turn_start?(e) ->
          {payload(e)["phase"], acc}

        e.type in [:action, "action"] and phase == "combat" and MapSet.member?(humans, e.actor) ->
          turn_rest = take_until(Enum.drop(events, i + 1), &turn_start?/1)
          rolled? = Enum.any?(turn_rest, &(dice?(&1) and &1.actor == e.actor))

          if rolled?,
            do: {phase, acc},
            else: {phase, [%{seq: e.seq, actor: e.actor, text: text(e)} | acc]}

        true ->
          {phase, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # ------------------------------------------------------------ helpers

  @doc false
  def stats([]), do: %{count: 0, p50: 0, p90: 0, max: 0, samples: []}

  def stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    rank = fn p -> Enum.at(sorted, max(ceil(p * n) - 1, 0)) end
    %{count: n, p50: rank.(0.5), p90: rank.(0.9), max: List.last(sorted), samples: sorted}
  end

  defp fmt_stats(%{count: 0}), do: "sin datos"
  defp fmt_stats(s), do: "n=#{s.count} p50 #{s.p50} · p90 #{s.p90} · máx #{s.max}"

  defp actor_kind("dm", _humans), do: :dm
  defp actor_kind(actor, humans), do: if(MapSet.member?(humans, actor), do: :human, else: :ai_pc)

  defp turn_start?(e), do: e.type in [:turn, "turn"] and payload(e)["kind"] == "start"
  defp dice?(e), do: e.type in [:dice, "dice"]

  defp handoff?(e),
    do:
      e.type in [:system, "system"] and
        (e.actor == "turnmaster" or kind?(e, "turnmaster_fallback"))

  defp handoff_to?(e, actor), do: handoff?(e) and payload(e)["to"] == actor

  defp human_return_after(events, i, actor) do
    events
    |> Enum.drop(i + 1)
    |> Enum.reduce_while(nil, fn event, _ ->
      cond do
        event.type in [:action, "action"] and event.actor == actor -> {:halt, nil}
        unknown_fallback?(event) -> {:halt, nil}
        handoff_to?(event, actor) -> {:halt, event}
        true -> {:cont, nil}
      end
    end)
  end

  defp unknown_fallback?(event) do
    handoff?(event) and kind?(event, "turnmaster_fallback") and
      case payload(event)["to"] do
        to when is_binary(to) -> String.trim(to) == ""
        _ -> true
      end
  end

  defp failure?(e) do
    e.type in [:system, "system"] and
      (payload(e)["kind"] == "turn_failed" or
         String.starts_with?(payload(e)["note"] || "", @failure_prefixes))
  end

  defp kind?(e, kind), do: payload(e)["kind"] == kind
  defp count_kind(events, kind), do: Enum.count(events, &kind?(&1, kind))

  defp find_after(events, i, fun), do: events |> Enum.drop(i + 1) |> Enum.find(fun)
  defp between(events, from, to), do: Enum.filter(events, &(&1.seq > from and &1.seq < to))
  defp take_until(events, fun), do: Enum.take_while(events, &(not fun.(&1)))

  defp seconds(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.diff(b, a)
  defp seconds(%DateTime{} = a, %DateTime{} = b), do: DateTime.diff(b, a)

  defp payload(%{payload: p}) when is_map(p), do: p
  defp payload(_), do: %{}

  defp text(e), do: payload(e)["text"] || ""
end
