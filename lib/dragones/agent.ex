defmodule Dragones.Agent do
  @moduledoc """
  Shared plumbing for the DM and PC agents.

  Both agents compact long histories the same way: when the message list crosses
  a threshold, a cheap summarizer model recaps the old messages into a short note
  so the agent keeps its context without re-sending every old turn. The
  summarizer-build + run + fallback logic, and the prompt envelope that wraps the
  transcript, are identical — so they live here. Each agent supplies its own
  summarizer system prompt and its own per-message transcript formatter (the DM
  and the PC label narration differently).
  """

  @doc """
  Run a cheap `summarizer` model to recap `messages` into a short string.

  `instructions` is the summarizer's system prompt. `to_line` maps each message
  to one transcript line (return `""` to skip a message). `log_tag` identifies
  which agent fired the compaction in the log line.

  Returns the recap text, or a fixed fallback if the summarizer run fails.
  """
  @spec summarize(term(), String.t(), [term()], (term() -> String.t()), String.t()) :: String.t()
  def summarize(summarizer, instructions, messages, to_line, log_tag) do
    require Logger

    Logger.info(
      "#{log_tag}: compaction fired — summarizing #{length(messages)} old messages via #{ExAgent.Model.model_name(summarizer)}"
    )

    body = Enum.map_join(messages, "\n", to_line)
    agent = ExAgent.new(model: summarizer, instructions: instructions)

    case ExAgent.run(agent, "Resume estos turnos anteriores de la partida:\n\n#{body}") do
      {:ok, %{output: text}} when is_binary(text) -> text
      _ -> "(earlier turns recap unavailable)"
    end
  end
end
