defmodule Dragonex.Game.InventoryResolution do
  @moduledoc """
  Requires the exploration DM beat that answers a declared pickup or handover
  («cojo el libro», «se lo doy a Mira») to leave an inventory receipt before
  its closure is published (D239): `grant_item`, `remove_item`, or
  `confirm_inventory_unchanged` when the object does not change hands.

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

  @doc "Pending requirement for this beat, or nil."
  def request("dm", %World{phase: :exploration}, events) do
    with %{actor: actor, payload: %{"text" => text}, seq: seq} <- pending_declaration(events),
         kind when not is_nil(kind) <- InventoryDeclaration.kind(text, Dragonex.I18n.locale()) do
      %{actor: actor, kind: kind, seq: seq}
    else
      _ -> nil
    end
  end

  def request(_, _, _), do: nil

  # The latest player declaration still waiting for the world's answer: no DM
  # narration after it (same window as Instructions.inventory_instruction/3).
  defp pending_declaration(events) do
    recent = events |> Enum.reverse() |> Enum.filter(&(Map.get(&1, :visible_to) in ["all", "dm"]))
    action = Enum.find(recent, &(&1.type == :action))
    previous_dm = Enum.find(recent, &(&1.type == :narration and &1.actor == "dm"))

    if action && (is_nil(previous_dm) || action.seq > previous_dm.seq), do: action
  end

  def resolved?(_world, nil, _turn_id), do: true
  def resolved?(%World{phase: :combat}, _request, _turn_id), do: true

  def resolved?(world, _request, turn_id) do
    case ToolReplay.restore(world, "dm") do
      %{turn_id: ^turn_id, tool_results: results} ->
        Enum.any?(results, fn {{name, _args}, values} -> name in @receipts and values != [] end)

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
