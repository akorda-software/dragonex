defmodule Dragonex.Test.ModelMessages do
  @moduledoc """
  Proyección semántica de los mensajes recibidos por TestModel para las aserciones
  de historia/rol. No representa ni certifica el transporte de un proveedor.
  Las pruebas HTTP de ReqLLM inspeccionan separadamente su body real.
  """
  alias ExAgent.Message.{Part, Request, Response}

  def project(messages), do: Enum.flat_map(messages, &message/1)

  def imported?(%{"role" => "user", "content" => content}, text) when is_binary(content),
    do: String.starts_with?(content, "CRÓNICA REGISTRADA") and String.contains?(content, text)

  def imported?(_, _), do: false

  defp message(%Request{parts: parts}), do: Enum.map(parts, &request_part/1)

  defp message(%Response{} = response) do
    [%{"role" => "assistant", "content" => Response.text(response)}]
  end

  defp request_part(%Part.System{content: text}), do: %{"role" => "system", "content" => text}
  defp request_part(%Part.User{content: text}), do: %{"role" => "user", "content" => text}

  defp request_part(%Part.ToolReturn{content: text, tool_call_id: id}),
    do: %{"role" => "tool", "content" => text_content(text), "tool_call_id" => id}

  defp request_part(%Part.Retry{content: text, tool_name: nil}),
    do: %{"role" => "user", "content" => text_content(text)}

  defp request_part(%Part.Retry{content: text, tool_call_id: id}),
    do: %{"role" => "tool", "content" => text_content(text), "tool_call_id" => id}

  defp text_content(text) when is_binary(text), do: text
  defp text_content(text), do: Jason.encode!(text)
end
