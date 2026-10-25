defmodule Dragonex.GameAI.OwnKeyModel do
  @moduledoc """
  A provider model bound to one saved credential generation. Admission is
  checked immediately before IO; active requests are registered so withdrawing
  or replacing the key cancels them, including probes and summarization.
  The lock protects admission only and is never held during provider IO.
  """

  @behaviour ExAgent.Model
  @derive {Inspect, only: [:user_id, :provider]}
  defstruct [:inner, :user_id, :provider, :version]

  alias Dragonex.Game.KeyRevocation
  alias ExAgent.Model

  @impl true
  def request(model, messages, settings, params) do
    with :ok <- KeyRevocation.admit(model) do
      try do
        case Model.request(model.inner, messages, settings, params) do
          {:ok, response, inner} -> {:ok, response, %{model | inner: inner}}
          error -> error
        end
      after
        KeyRevocation.release(model)
      end
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    Stream.resource(
      fn ->
        case KeyRevocation.admit(model) do
          :ok ->
            stream = Model.request_stream(model.inner, messages, settings, params)
            {:open, stream, model}

          error ->
            {:error, error, model}
        end
      end,
      &next/1,
      &close/1
    )
  end

  defp next({:error, error, model}), do: {[error], {:done, nil, model}}
  defp next({:done, _, _} = state), do: {:halt, state}

  defp next({kind, source, model}) do
    result =
      case kind do
        :open -> Enumerable.reduce(source, {:cont, nil}, fn event, _ -> {:suspend, event} end)
        :next -> source.({:cont, nil})
      end

    case result do
      {:suspended, {:response, response, inner}, continuation} ->
        {[{:response, response, %{model | inner: inner}}], {:done, continuation, model}}

      {:suspended, {:error, _} = error, continuation} ->
        {[error], {:done, continuation, model}}

      {:suspended, event, continuation} ->
        {[event], {:next, continuation, model}}

      {status, _} when status in [:done, :halted] ->
        {:halt, {:done, nil, model}}
    end
  end

  defp close({kind, continuation, model}) do
    try do
      if kind in [:next, :done] and is_function(continuation, 1),
        do: continuation.({:halt, nil})
    after
      KeyRevocation.release(model)
    end
  end

  @impl true
  def model_name(model), do: Model.model_name(model.inner)
  @impl true
  def system(model), do: Model.system(model.inner)
  @impl true
  def profile(model), do: Model.profile(model.inner)
end
