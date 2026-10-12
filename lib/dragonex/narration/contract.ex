defmodule Dragonex.Narration.Contract do
  @moduledoc """
  Boundary for structured narration in the DM, PC and manual resolver runs.

  Use with `output: Dragonex.Narration` and Events. Free response text stays
  in the native private continuation; Events does not publish it and this
  capability suppresses raw deltas. After the run succeeds, call
  publish_result/2: a schema alone is insufficient evidence of completion.
  The terminal output must be isolated, paired with its native successful
  return and compatible with the beat's current resolution requirements.

  This boundary never executes skipped tools or modifies native tool frames.
  Game owns durable publication/checkpoints; no rule outcome or cost originates
  here. Rejected completion preserves all already paid effects.
  """
  use ExAgent.Capability
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Events, Narration}
  alias Dragonex.Game.{InventoryResolution, NPCMemoryResolution, RunLifecycle, WaitResolution}
  alias ExAgent.Message.{Part, Request, Response}

  @incomplete [:length, :content_filter, :unknown, :incomplete, :error]

  @doc "Stable instructions for the explicit public narration protocol."
  def instruction do
    dgettext(
      "prompts",
      "SALIDA PÚBLICA: el texto libre de tus respuestas es privado y no se publica. " <>
        "Para una declaración o reacción intermedia usa narrate con text, sin deliberación interna. " <>
        "Resuelve reglas con las herramientas correspondientes y consulta sus resultados. " <>
        "Cierra con una llamada aislada a final_result con text: no la combines con ninguna otra herramienta. " <>
        "Lo publicado con narrate ya está a la vista: final_result continúa desde ahí con lo nuevo " <>
        "(resultados y consecuencias), sin copiarlo, citarlo de nuevo ni parafrasearlo. " <>
        "Solo el texto validado se publicará. No des por resueltas esperas ni aclaraciones de PNJ sin su comprobante. " <>
        "Al resolver una declaración humana no escribas nuevas palabras o gestos del jugador; " <>
        "omite narrate y devuelve un reconocimiento breve mediante final_result."
    )
  end

  @doc "Identify failed public closure without treating it as a completed actor turn."
  def error?({:narration_contract, _}), do: true
  def error?({:unexpected_model_behavior, {:output_retries_exhausted, _}}), do: true
  def error?({:content_filter, _}), do: true
  def error?({:incomplete_model_response, finish}) when finish in @incomplete, do: true

  def error?(
        {:model_request_failed, %ExAgent.RequestError{reason: {:incomplete_response, finish}}}
      )
      when finish in [:content_filter, :unknown, :incomplete, :error],
      do: true

  def error?(_), do: false

  def feedback({:narration_contract, reason}), do: feedback(reason)

  def feedback(:mixed_completion),
    do:
      dgettext(
        "prompts",
        "El cierre fue rechazado: las herramientas junto a final_result no se ejecutaron."
      ) <> " " <> instruction()

  def feedback(:wait_unresolved),
    do: dgettext("prompts", "Registra primero la resolución de la espera con advance_time.")

  def feedback(:npc_memory_unresolved),
    do:
      dgettext(
        "prompts",
        "Registra primero la aclaración de la fuente pendiente con record_npc_statement."
      )

  def feedback(:inventory_unresolved),
    do:
      dgettext(
        "prompts",
        "Registra primero el inventario: grant_item, remove_item o confirm_inventory_unchanged."
      )

  def feedback(:human_voice_owned),
    do:
      dgettext("prompts", "La voz del jugador procede de su declaración original; omite narrate.") <>
        " " <> instruction()

  def feedback(_),
    do:
      dgettext(
        "prompts",
        "La narración pública necesita text no vacío, UTF-8 válido y hasta 8000 caracteres."
      ) <> " " <> instruction()

  @impl true
  def before_model_request(_cap, %{agent: %{output_type: Narration}} = state) do
    Dragonex.I18n.adopt(state.deps)

    deps =
      if is_map(state.deps),
        do: Map.put(state.deps, :on_text_delta, fn _chunk -> :ok end),
        else: state.deps

    %{state | deps: deps, params: %{state.params | allow_text_output: false}}
  end

  def before_model_request(_cap, state), do: state

  @doc "Publish only a completed structured result whose required effects are committed."
  def publish_result(%{output: %Narration{text: text}} = result, deps) do
    with :ok <- completion(result),
         :ok <- requirements(deps),
         {:ok, speech} <- Events.publish_completed_speech(deps, text) do
      {:ok, speech}
    else
      {:error, reason} -> {:error, {:narration_contract, reason}}
    end
  end

  def publish_result(_, _), do: {:error, {:narration_contract, :invalid_output}}

  @doc "Publish explicit intermediate prose without making a completion receipt."
  def publish_intermediate(attrs, deps) do
    with {:ok, %Narration{text: text}} <- ExAgent.OutputSchema.validate(Narration, attrs),
         :ok <- requirements(deps),
         :ok <- model_voice(deps),
         {:ok, speech} <- Events.publish_intermediate_speech(deps, text) do
      {:ok, speech}
    else
      {:error, reason} -> {:error, {:narration_contract, reason}}
    end
  end

  defp model_voice(%{beat: %{human_declaration: text}}) when is_binary(text) and text != "",
    do: {:error, :human_voice_owned}

  defp model_voice(_), do: :ok

  # Only the last Response in this run can prove its completion. Looking in
  # full messages could mistake a previous beat's final_result for this one.
  defp completion(%{output: output, new_messages: messages}) when is_list(messages) do
    case Enum.reverse(messages) do
      [%Request{parts: returns}, %Response{finish_reason: finish} = response | _]
      when finish not in @incomplete ->
        case Response.tool_calls(response) do
          [%Part.ToolCall{tool_name: "final_result"} = call] ->
            with {:ok, args} <- args(call.args),
                 {:ok, ^output} <- ExAgent.OutputSchema.validate(Narration, args),
                 true <- successful_return?(returns, call) do
              :ok
            else
              _ -> {:error, :invalid_completion}
            end

          [_, _ | _] ->
            {:error, :mixed_completion}

          _ ->
            {:error, :invalid_completion}
        end

      _ ->
        {:error, :invalid_completion}
    end
  end

  defp completion(_), do: {:error, :invalid_completion}

  defp args(args) when is_map(args), do: {:ok, args}
  defp args(args) when is_binary(args), do: Jason.decode(args)
  defp args(_), do: {:error, :invalid_args}

  # Success needs the paired "ok" and an explicit succeeded status (a forged
  # status on an otherwise native return is rejected).
  defp successful_return?(
         [
           %Part.ToolReturn{
             tool_name: "final_result",
             tool_call_id: id,
             content: "ok",
             status: :succeeded
           }
         ],
         %Part.ToolCall{tool_call_id: id}
       ),
       do: true

  defp successful_return?(_, _), do: false

  defp requirements(%{beat: %{game_id: game_id, actor: actor, turn_id: turn_id}} = deps)
       when is_integer(game_id) and game_id > 0 and is_binary(actor) and actor != "" and
              is_binary(turn_id) and turn_id != "" do
    cond do
      not RunLifecycle.alive?(deps) -> {:error, :cancelled}
      WaitResolution.waiting?(deps) -> {:error, :wait_unresolved}
      NPCMemoryResolution.waiting?(deps) -> {:error, :npc_memory_unresolved}
      InventoryResolution.waiting?(deps) -> {:error, :inventory_unresolved}
      true -> :ok
    end
  end

  defp requirements(_), do: {:error, :invalid_context}
end
