defmodule Dragonex.Agent.LegacyHistory do
  @moduledoc """
  Frontera temporal para exAgent 1.2 de Hex: su Server ignora message_history
  por chat. La capability inicializa el run con los eventos compartidos de Game
  antes de compactar, conservando el índice de mensajes nuevos y las siguientes
  respuestas de herramientas. No modifica procesos ni el World. Se retira al
  adoptar en producción la versión de Hex con override nativo de historial.
  """
  use ExAgent.Capability

  @impl true
  def before_model_request(_cap, %{run_step: 1, deps: %{shared_history: history}} = state)
      when is_list(history) do
    current = Enum.drop(state.messages, state.first_new_message_index)

    %{
      state
      | messages: history ++ current,
        request_messages: nil,
        first_new_message_index: length(history)
    }
  end

  def before_model_request(_cap, state), do: state
end
