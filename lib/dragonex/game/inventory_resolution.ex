defmodule Dragonex.Game.InventoryResolution do
  @moduledoc """
  Requires the exploration DM beat that answers a declared pickup or handover
  («cojo el libro», «se lo doy a Mira») to leave an inventory receipt before
  its closure is published (D239): `grant_item`, `remove_item`, or
  `confirm_inventory_unchanged` when the object does not change hands.

  Temporary loans with a return in the same episode require an atomic
  `record_item_round_trip` or a typed `confirm_no_inventory_transfer`.
  Net-zero stock alone cannot prove either outcome.

  The prompt already asked for this (INVENTARIO OBLIGATORIO), but playtests
  showed the model sometimes narrating the delivery without touching stock.
  Like WaitResolution/NPCMemoryResolution, this never writes the World: it
  only withholds publication until the current actor receipt exists.
  """
  use ExAgent.Capability
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{InventoryDeclaration, World}
  alias Dragonex.Game.{NPCMemoryResolution, ToolReplay, WaitResolution}
  alias ExAgent.Session.SharedState

  @receipts ["grant_item", "remove_item", "confirm_inventory_unchanged"]
  @decisions ["record_item_round_trip", "confirm_no_inventory_transfer"]
  @inventory_tools @receipts ++ @decisions
  @legacy_effects ["grant_item", "remove_item"]
  @no_transfer_outcomes ["declined", "not_available", "look_only"]

  @doc "Pending requirement for this beat, or nil."
  def request(participant, world, events),
    do: request(participant, world, events, &InventoryDeclaration.kind/2)

  @doc "Preserve D239 for a resumed checkpoint that predates the captured inventory requirement."
  def legacy_request(participant, world, events),
    do: request(participant, world, events, &InventoryDeclaration.legacy_kind/2)

  defp request("dm", %World{phase: :exploration}, events, classify) do
    with %{actor: actor, payload: %{"text" => text}, seq: seq} <- pending_declaration(events),
         kind when not is_nil(kind) <- classify.(text, Dragonex.I18n.locale()) do
      %{actor: actor, kind: kind, seq: seq}
    else
      _ -> nil
    end
  end

  defp request(_, _, _, _), do: nil

  # An explicitly intermediate DM narration does not answer the declaration.
  # Completed narration does; legacy narration without this field keeps its
  # previous interpretation for historical conversations.
  defp pending_declaration(events) do
    recent = events |> Enum.reverse() |> Enum.filter(&(Map.get(&1, :visible_to) in ["all", "dm"]))
    action = Enum.find(recent, &(&1.type == :action))

    previous_dm =
      Enum.find(recent, fn event ->
        event.type == :narration and event.actor == "dm" and
          Map.get(event.payload || %{}, "complete") != false
      end)

    if action && (is_nil(previous_dm) || action.seq > previous_dm.seq), do: action
  end

  def resolved?(_world, nil, _turn_id), do: true
  def resolved?(%World{phase: :combat}, _request, _turn_id), do: true

  def resolved?(world, request, turn_id) do
    case ToolReplay.restore(world, "dm") do
      %{turn_id: ^turn_id, tool_results: results} ->
        Enum.any?(results, fn {{name, args}, values} ->
          args["who"] == request.actor and values != [] and receipt?(request, name, args)
        end)

      _ ->
        false
    end
  end

  def waiting?(%{
        state: %SharedState{} = shared,
        beat: %{actor: "dm", inventory_resolution: request, turn_id: turn_id}
      })
      when is_map(request),
      do: not resolved?(SharedState.read(shared), request, turn_id)

  def waiting?(_), do: false

  # Tools perform this cheap guard before preparing a change. Admission and
  # commit run validate_commit/2 again inside Game, closing the parallel-call
  # window and retaining one decision even when its final stock delta is zero.
  def assert_tool_allowed(ctx, name, who) do
    deps = Map.get(ctx, :deps, %{})
    beat = Map.get(deps, :beat, %{})
    expected_turn_id = Map.get(beat, :turn_id)

    results =
      case deps[:state] do
        %SharedState{} = shared ->
          case ToolReplay.restore(SharedState.read(shared), "dm") do
            %{turn_id: turn_id, tool_results: results} when turn_id == expected_turn_id -> results
            _ -> %{}
          end

        _ ->
          %{}
      end

    validate_commit(Map.put(beat, :tool_results, results), {name, %{"who" => who}})
  end

  @doc "Validate inventory admission/commit against the current beat's paid receipts."
  def validate_commit(beat, {name, args})
      when name in @inventory_tools and is_map(args) do
    request = Map.get(beat, :inventory_resolution)
    results = Map.get(beat, :tool_results, %{})
    who = args["who"]
    round_trip? = match?(%{kind: :round_trip}, request)
    pending_actor? = round_trip? and request.actor == who

    cond do
      round_trip? and name in @decisions and not pending_actor? ->
        {:error,
         dgettext("engine", "Resuelve el préstamo pendiente de %{who}, no el de otro personaje.",
           who: request.actor
         )}

      paid?(results, @decisions, who) ->
        {:error,
         dgettext(
           "engine",
           "El inventario de %{who} ya tiene una resolución registrada en este turno. No añadas otro préstamo ni cambies su resultado.",
           who: who
         )}

      (pending_actor? or name in @decisions) and paid?(results, @legacy_effects, who) ->
        {:error,
         dgettext(
           "engine",
           "Hay una entrega o retirada anterior ya pagada para %{who}. No registres otro préstamo ni infieras el orden de esos comprobantes. Continúa desde el inventario actual con las herramientas previas del turno, sin repetir los efectos pagados.",
           who: who
         )}

      pending_actor? and name in @receipts ->
        {:error,
         dgettext(
           "engine",
           "El préstamo y la devolución inmediata requieren record_item_round_trip, o confirm_no_inventory_transfer si no hubo entrega. Un saldo final igual no significa que no cambió de manos."
         )}

      true ->
        :ok
    end
  end

  def validate_commit(_beat, _key), do: :ok

  defp paid?(results, names, who) do
    Enum.any?(results, fn {{name, args}, values} ->
      name in names and args["who"] == who and values != []
    end)
  end

  defp receipt?(_request, "record_item_round_trip", _args), do: true

  defp receipt?(_request, "confirm_no_inventory_transfer", args),
    do: args["outcome"] in @no_transfer_outcomes

  defp receipt?(%{kind: :round_trip}, _name, _args), do: false
  defp receipt?(_request, name, _args), do: name in @receipts

  @impl true
  def before_model_request(_cap, %{deps: %{beat: %{inventory_resolution: request}}} = state)
      when is_map(request) do
    waiting =
      waiting?(state.deps) or WaitResolution.waiting?(state.deps) or
        NPCMemoryResolution.waiting?(state.deps)

    %{state | params: %{state.params | allow_text_output: not waiting}}
  end

  def before_model_request(_cap, state), do: state

  def instruction(nil), do: ""

  def instruction(%{actor: actor, kind: :round_trip}) do
    "\n\n" <>
      dgettext(
        "prompts",
        "PRÉSTAMO Y DEVOLUCIÓN PENDIENTES: %{actor} propone una entrega temporal con devolución inmediata. " <>
          "Si ocurre, registra ambos tramos juntos con record_item_round_trip antes de narrar. " <>
          "El saldo final puede ser idéntico: eso no elimina las dos transferencias. " <>
          "Si no llega a cambiar de manos, usa confirm_no_inventory_transfer para %{actor} con outcome " <>
          "declined (rechazado), not_available (no disponible) o look_only (solo lo observa sin recibirlo). " <>
          "No uses confirm_inventory_unchanged ni grant_item/remove_item separados para este episodio. " <>
          "No repitas una resolución pagada ni infieras el orden de comprobantes antiguos; conserva sus efectos.",
        actor: actor
      )
  end

  def instruction(%{actor: actor}) do
    "\n\n" <>
      dgettext(
        "prompts",
        "RECOGIDA O ENTREGA PENDIENTE: %{actor} acaba de declarar que recoge o entrega un objeto. " <>
          "Antes de cerrar con final_result, registra lo que ocurre de verdad: grant_item si %{actor} " <>
          "recibe el objeto, remove_item si lo entrega o lo deja, o confirm_inventory_unchanged si no " <>
          "cambia de manos (no está, el intento falla, solo lo mira o ya figura en su inventario). " <>
          "El motor no publicará tu cierre sin uno de esos comprobantes en este turno. " <>
          "No concedas otra vez un objeto que ya figura en el inventario del resumen.",
        actor: actor
      )
  end
end
