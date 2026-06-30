defmodule Dragones.Game.BeatTest do
  @moduledoc """
  The beat retry policy decides whether a failed beat is worth retrying (transient
  provider fault) and how to phrase a soft fallback. Lock the classification —
  especially the `transient_body?` keyword list, which only "rate"/"try again"
  covered before.
  """

  use ExUnit.Case, async: true

  alias Dragones.Game.Beat
  alias ExAgent.RequestError

  defp provider_error(body),
    do: {:model_request_failed, %RequestError{provider: :test, reason: :provider_error, body: body}}

  describe "max_tokens_error?/1" do
    test "the bare atom and the {atom, model} tuple" do
      assert Beat.max_tokens_error?(:max_tokens_exceeded)
      assert Beat.max_tokens_error?({:max_tokens_exceeded, "deepseek-chat"})
    end

    test "anything else is not a max-tokens error" do
      refute Beat.max_tokens_error?({:crashed, :oops})
      refute Beat.max_tokens_error?(:nope)
      refute Beat.max_tokens_error?("max_tokens_exceeded")
    end
  end

  describe "transient_provider_error?/1" do
    test "transport-level faults are transient" do
      assert Beat.transient_provider_error?({:model_request_failed, %RequestError{provider: :test, reason: :timeout}})
      assert Beat.transient_provider_error?({:model_request_failed, %RequestError{provider: :test, reason: :request_failed}})
    end

    test "HTTP 429 and any 5xx are transient; 4xx is not" do
      assert Beat.transient_provider_error?({:model_request_failed, %RequestError{provider: :test, reason: :http_error, status: 429}})
      assert Beat.transient_provider_error?({:model_request_failed, %RequestError{provider: :test, reason: :http_error, status: 503}})
      assert Beat.transient_provider_error?({:model_request_failed, %RequestError{provider: :test, reason: :http_error, status: 529}})
      refute Beat.transient_provider_error?({:model_request_failed, %RequestError{provider: :test, reason: :http_error, status: 400}})
    end

    # Every keyword `transient_body?/1` looks for. A provider_error body carrying
    # any of these should classify as transient (worth retrying).
    @transient_keywords [
      "rate limited",
      "overloaded",
      "capacity",
      "temporarily unavailable",
      "please try again",
      "gateway timeout",
      "service unavailable",
      "HTTP 503",
      "error 529",
      "internal error"
    ]

    test "provider_error bodies with a transient keyword are transient" do
      for body <- @transient_keywords do
        assert Beat.transient_provider_error?(provider_error(body)),
               "expected transient for body: #{inspect(body)}"
      end
    end

    test "provider_error bodies without a transient keyword are NOT transient" do
      refute Beat.transient_provider_error?(provider_error("bad request"))
      refute Beat.transient_provider_error?(provider_error("invalid api key"))
      refute Beat.transient_provider_error?(provider_error(%{"something" => "else"}))
    end

    test "a crashed Task is not a provider fault, and unknown reasons are not transient" do
      refute Beat.transient_provider_error?({:crashed, :badarg})
      refute Beat.transient_provider_error?({:whatever, "nope"})
      refute Beat.transient_provider_error?(:totally_unknown)
    end
  end

  describe "transient_backoff/1" do
    # Default slots: [1_000, 3_000, 10_000], then cap at the last.
    test "the default backoff slots, then cap" do
      assert Beat.transient_backoff(0) == 1_000
      assert Beat.transient_backoff(1) == 3_000
      assert Beat.transient_backoff(2) == 10_000
      assert Beat.transient_backoff(3) == 10_000
      assert Beat.transient_backoff(99) == 10_000
    end
  end

  describe "fallback_narration/2" do
    test "max_tokens: DM vs PC get distinct lines" do
      assert Beat.fallback_narration("dm", :max_tokens_exceeded) =~ "narrador recupera el hilo"
      assert Beat.fallback_narration("Lyra", {:max_tokens_exceeded, "x"}) =~ "empieza a decir algo"
    end

    test "unexpected_model_behavior: DM vs PC distinct lines" do
      assert Beat.fallback_narration("dm", {:unexpected_model_behavior, :x}) =~ "respiración"
      assert Beat.fallback_narration("Thane", {:unexpected_model_behavior, :x}) =~ "duda"
    end

    test "any other reason: DM vs PC distinct lines" do
      assert Beat.fallback_narration("dm", {:crashed, :oops}) =~ "pausa breve"
      assert Beat.fallback_narration("Vex", {:crashed, :oops}) =~ "titubea"
    end
  end

  describe "brief_retry_instruction/2" do
    test "prepends the brevity nudge to the original instruction" do
      out = Beat.brief_retry_instruction("Es el turno de Vex.", "Vex")
      assert String.starts_with?(out, "⏱")
      assert out =~ "Es el turno de Vex."
    end

    test "falls back to a default line when the original is nil" do
      out = Beat.brief_retry_instruction(nil, "Lyra")
      assert out =~ "Es el turno de Lyra."
    end
  end
end
