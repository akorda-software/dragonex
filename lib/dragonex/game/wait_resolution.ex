defmodule Dragonex.Game.WaitResolution do
  @moduledoc """
  Requires a DM to settle a newly declared timed wait before final speech.
  The action event carries the source and initial clock; World/tool receipts
  prove the interval was resolved. No clock change originates in this hook.
  """
  use ExAgent.Capability
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.World
  alias ExAgent.Session.SharedState

  def request("dm", %World{phase: :exploration}, events) do
    action = events |> Enum.reverse() |> Enum.find(&(&1.type == :action))

    with %{payload: %{"wait_seconds" => seconds, "clock_before" => start}} <- action,
         true <- is_integer(seconds) and seconds > 0 and seconds <= 86400,
         true <- is_integer(start) and start >= 0,
         false <-
           Enum.any?(
             events,
             &(&1.seq > action.seq and &1.actor == "dm" and &1.type == :narration and
                 &1.payload["complete"] == true)
           ) do
      %{
        seconds: seconds,
        clock_before: start,
        actor: action.actor,
        declaration: action.payload["text"],
        source_turn_id: action.payload["turn_id"]
      }
    else
      _ -> nil
    end
  end

  def request(_, _, _), do: nil

  # Recovery can already have complete DM speech while its scene review is
  # unfinished. This request identifies the committed interval; it does not
  # require another model call or another application of elapsed time.
  def review_request(%World{phase: :exploration, wait_resolution: receipt}, events)
      when is_map(receipt) do
    action = events |> Enum.reverse() |> Enum.find(&(&1.type == :action))

    with %{payload: %{"wait_seconds" => seconds, "clock_before" => start, "turn_id" => source}} <-
           action,
         true <- is_binary(source) and source != "",
         true <-
           receipt["source_turn_id"] == source and receipt["declared_seconds"] == seconds and
             receipt["clock_before"] == start do
      %{seconds: seconds, clock_before: start, source_turn_id: source}
    else
      _ -> nil
    end
  end

  def review_request(_, _), do: nil

  def resolved?(_world, nil, _turn_id), do: true
  def resolved?(%World{phase: :combat}, _request, _turn_id), do: true

  def resolved?(world, request, _turn_id) do
    receipt = Map.get(world, :wait_resolution) || %{}

    world.elapsed_seconds >= request.clock_before + request.seconds or
      receipt["source_turn_id"] == request.source_turn_id
  end

  def waiting?(%{
        state: %SharedState{} = shared,
        beat: %{actor: "dm", wait_resolution: request, turn_id: turn_id}
      })
      when is_map(request),
      do: not resolved?(SharedState.read(shared), request, turn_id)

  def waiting?(_), do: false

  @impl true
  def before_model_request(
        _cap,
        %{deps: %{beat: %{actor: "dm", wait_resolution: request}}} = state
      )
      when is_map(request) do
    waiting = waiting?(state.deps)

    # Unresolved final text is rejected, and this flag reaches the current
    # provider request.
    params = %{state.params | allow_text_output: not waiting}

    %{state | params: params}
  end

  def before_model_request(_cap, state), do: state

  def instruction(nil, _world, _turn_id), do: ""

  def instruction(request, world, turn_id) do
    if resolved?(world, request, turn_id) do
      "\n" <>
        dgettext(
          "prompts",
          "ESPERA YA REGISTRADA: consulta el reloj vigente; no repitas este intervalo de %{actor}.",
          actor: request.actor
        )
    else
      "\n" <>
        dgettext(
          "prompts",
          "ESPERA DECLARADA PENDIENTE por %{actor}: %{declaration}\n" <>
            "El motor calcula su duración completa: %{seconds} segundos. Reloj antes: %{clock_before} s. " <>
            "Antes de cerrar tu respuesta, llama advance_time con esos segundos si se completa. " <>
            "Si un suceso interrumpe la espera, registra solo los segundos realmente transcurridos (0..%{seconds}) y explica la interrupción. " <>
            "No des por terminada la espera sin registrar su resolución. No es un descanso ni concede recursos. " <>
            "Una vez confirmada, no vuelvas a sumar el intervalo.",
          actor: request.actor,
          declaration: request.declaration,
          seconds: request.seconds,
          clock_before: request.clock_before
        )
    end
  end

  # Runs inside RuleCheckpoint's change function, so even parallel tool calls
  # inspect the latest committed receipt rather than a stale tool-side World.
  def advance_time(world, seconds, %{
        beat: %{actor: "dm", wait_resolution: request, turn_id: turn_id}
      })
      when is_map(request) do
    cond do
      not is_integer(seconds) or seconds < 0 or seconds > request.seconds ->
        {:error,
         dgettext("engine", "registra entre 0 y %{seconds} segundos para esta espera declarada",
           seconds: request.seconds
         )}

      world.phase == :combat ->
        World.advance_time(seconds).(world)

      resolved?(world, request, turn_id) ->
        {:ok, world}

      true ->
        World.resolve_wait(request.source_turn_id, request.seconds, seconds).(world)
    end
  end

  def advance_time(world, seconds, _), do: World.advance_time(seconds).(world)
end
