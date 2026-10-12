defmodule Dragonex.Agent do
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

  use Gettext, backend: Dragonex.Gettext

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

    case ExAgent.run(
           agent,
           dgettext("prompts", "Resume estos turnos anteriores de la partida:") <> "\n\n" <> body
         ) do
      {:ok, %{output: text}} when is_binary(text) -> text
      _ -> "(earlier turns recap unavailable)"
    end
  end

  @doc "Conserva N mensajes anteriores además de la petición activa (exAgent 2.x la cuenta)."
  def compaction_window(n), do: n + 1

  @doc "Historial explícito de Game en Server, incluida la versión publicada 1.2."
  def chat(server, prompt, opts \\ []) do
    opts =
      case Keyword.fetch(opts, :message_history) do
        {:ok, history} ->
          Keyword.update(
            opts,
            :deps,
            %{shared_history: history},
            &Map.put(&1, :shared_history, history)
          )

        :error ->
          opts
      end

    ExAgent.Server.chat(server, prompt, opts)
  end

  @doc false
  def capabilities(capabilities) do
    Enum.each(capabilities, fn cap ->
      module = if is_atom(cap), do: cap, else: cap.__struct__
      Code.ensure_loaded!(module)
    end)

    capabilities
  end
end
