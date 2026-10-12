defmodule Dragonex.Game.NPCMemoryResolution do
  @moduledoc """
  Requires a literal clarification of prior NPC speech to be acknowledged by
  record_npc_statement before the DM's answer is published. The current actor
  tool receipt proves commitment, including a duplicate retained testimony.
  This capability never derives facts from prose or writes the World.
  """
  use ExAgent.Capability
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Text, World}
  alias Dragonex.Game.{Participants, ToolReplay, WaitResolution}
  alias ExAgent.Session.SharedState

  def request(
        "dm",
        %World{
          phase: :exploration,
          conversation: %{
            "stage" => "world",
            "world_recipient" => recipient,
            "question" => question
          }
        } = world
      ) do
    case Text.literal_npc_clarification(question, pc_names: Participants.pc_names(world)) do
      {^recipient, _speech} -> %{speaker: recipient}
      _ -> nil
    end
  end

  def request(_, _), do: nil

  def resolved?(_world, nil, _turn_id), do: true
  def resolved?(%World{phase: :combat}, _request, _turn_id), do: true

  def resolved?(world, %{speaker: speaker}, turn_id) do
    case ToolReplay.restore(world, "dm") do
      %{turn_id: ^turn_id, tool_results: results} ->
        Enum.any?(results, fn
          {{"record_npc_statement", %{"speaker" => recorded}}, [_ | _]} ->
            same_speaker?(speaker, recorded)

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  def waiting?(%{
        state: %SharedState{} = shared,
        beat: %{
          actor: "dm",
          npc_memory_resolution: request,
          turn_id: turn_id
        }
      })
      when is_map(request), do: not resolved?(SharedState.read(shared), request, turn_id)

  def waiting?(_), do: false

  @impl true
  def before_model_request(_cap, %{deps: %{beat: %{npc_memory_resolution: request}}} = state)
      when is_map(request) do
    waiting = waiting?(state.deps) or WaitResolution.waiting?(state.deps)
    %{state | params: %{state.params | allow_text_output: not waiting}}
  end

  def before_model_request(_cap, state), do: state

  def instruction(nil), do: ""

  def instruction(%{speaker: speaker}) do
    "\n\n" <>
      dgettext(
        "prompts",
        "ACLARACIÓN DE TESTIMONIO PENDIENTE: el jugador pide aclarar palabras previas de %{speaker}. " <>
          "Antes de cerrar tu respuesta, usa record_npc_statement con speaker «%{speaker}» y la aclaración concreta, " <>
          "conservando su fuente y dudas. Si no puede aclararlo, registra precisamente esa limitación; " <>
          "no inventes certeza ni otro testigo. El motor necesita el comprobante de esa herramienta en este turno, " <>
          "también si repites un testimonio retenido: repetirlo no duplica memoria ni renueva su reloj. " <>
          "No registres gestos ni ambiente para cumplir este requisito. Después responde con la voz de ese PNJ.",
        speaker: speaker
      )
  end

  def validate_speaker(%{beat: %{npc_memory_resolution: %{speaker: expected}}}, supplied) do
    if same_speaker?(expected, supplied),
      do: :ok,
      else:
        {:error,
         dgettext(
           "engine",
           "Esta aclaración corresponde a %{speaker}; registra su testimonio con esa fuente.",
           speaker: expected
         )}
  end

  def validate_speaker(_, _), do: :ok

  defp same_speaker?(a, b) when is_binary(a) and is_binary(b),
    do: speaker_key(a) == speaker_key(b)

  defp same_speaker?(_, _), do: false

  defp speaker_key(text) do
    text
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/^(?:el|la)\s+/u, "")
  end
end
