defmodule Dragonex.Test.Narrator do
  @moduledoc """
  A deterministic model that always calls final_result with its configured
  public text. It does not convert free text or inspect another model's
  response; malformed/raw-output tests keep their actual scripted models.
  """
  @behaviour ExAgent.Model
  defstruct text: "La escena está en calma. ¿Qué haces?"

  @impl true
  def request(model, _messages, _settings, _params),
    do: {:ok, Dragonex.Test.Harness.narration_response(model.text), model}

  @impl true
  def request_stream(model, messages, settings, params) do
    {:ok, response, updated} = request(model, messages, settings, params)
    [Dragonex.Test.Harness.stream_response(response, updated)]
  end

  @impl true
  def model_name(_), do: "deterministic-public-narrator"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: ExAgent.Models.Test.profile(%ExAgent.Models.Test{})
end
