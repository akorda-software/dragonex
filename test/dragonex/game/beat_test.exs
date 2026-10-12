defmodule Dragonex.Game.BeatTest do
  @moduledoc """
  The beat retry policy decides whether a failed beat is worth retrying (transient
  provider fault) and how to phrase a soft fallback. Lock the classification —
  especially the `transient_body?` keyword list, which only "rate"/"try again"
  covered before.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Game.Beat
  alias ExAgent.RequestError

  defp provider_error(body),
    do:
      {:model_request_failed, %RequestError{provider: :test, reason: :provider_error, body: body}}

  describe "max_tokens_error?/1" do
    test "the bare atom and the {atom, model} tuple" do
      assert Beat.max_tokens_error?(:max_tokens_exceeded)
      assert Beat.max_tokens_error?({:max_tokens_exceeded, "deepseek-chat"})
    end

    test "v2 incomplete length is retried briefly but unsupported finish reasons are not" do
      assert Beat.max_tokens_error?(
               {:model_request_failed,
                %RequestError{provider: :req_llm, reason: {:incomplete_response, :length}}}
             )

      refute Beat.max_tokens_error?(
               {:model_request_failed,
                %RequestError{provider: :req_llm, reason: {:incomplete_response, :content_filter}}}
             )
    end

    test "anything else is not a max-tokens error" do
      refute Beat.max_tokens_error?({:crashed, :oops})
      refute Beat.max_tokens_error?(:nope)
      refute Beat.max_tokens_error?("max_tokens_exceeded")
    end
  end

  describe "transient_provider_error?/1" do
    test "invalid generated v2 tool arguments can retry but schema and continuation failures cannot" do
      assert Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :req_llm, reason: :invalid_tool_arguments}}
             )

      for reason <- [
            :invalid_tool_schema,
            :invalid_tool_history,
            :continuation_routing_mismatch,
            {:unsupported, :tool_history_codec},
            :missing_credentials
          ] do
        refute Beat.transient_provider_error?(
                 {:model_request_failed, %RequestError{provider: :req_llm, reason: reason}}
               )
      end

      refute Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :openrouter, reason: :invalid_tool_arguments}}
             )
    end

    test "transport-level faults are transient" do
      assert Beat.transient_provider_error?(
               {:model_request_failed, %RequestError{provider: :test, reason: :timeout}}
             )

      assert Beat.transient_provider_error?(
               {:model_request_failed, %RequestError{provider: :test, reason: :request_failed}}
             )
    end

    test "v2 total timeout and HTTP faults retain the bounded retry policy" do
      assert Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :openrouter, reason: {:timeout, :total}}}
             )

      for status <- [429, 500, 503] do
        assert Beat.transient_provider_error?(
                 {:model_request_failed,
                  %RequestError{
                    provider: :openrouter,
                    reason: :model_request_failed,
                    status: status
                  }}
               )
      end

      for status <- [nil, 400, 401, 404] do
        refute Beat.transient_provider_error?(
                 {:model_request_failed,
                  %RequestError{
                    provider: :openrouter,
                    reason: :model_request_failed,
                    status: status
                  }}
               )
      end
    end

    test "HTTP 429 and any 5xx are transient; 4xx is not" do
      assert Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :test, reason: :http_error, status: 429}}
             )

      assert Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :test, reason: :http_error, status: 503}}
             )

      assert Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :test, reason: :http_error, status: 529}}
             )

      refute Beat.transient_provider_error?(
               {:model_request_failed,
                %RequestError{provider: :test, reason: :http_error, status: 400}}
             )
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

  describe "failure_label/1" do
    test "names the cause without in-fiction prose" do
      assert Beat.failure_label({:retention_limit_exceeded, %{bytes: 6300, limit: 4096}}) =~
               "tamaño permitido"

      assert Beat.failure_label({:unexpected_model_behavior, :x}) =~ "respuesta válida"
      assert Beat.failure_label({:crashed, :oops}) == "error interno del motor"
      assert Beat.failure_label(:whatever) == "error inesperado"
    end

    test "separates exhausted transient faults from rejected requests" do
      transient = %ExAgent.RequestError{provider: :openrouter, status: 503, reason: :http_error}
      rejected = %ExAgent.RequestError{provider: :openrouter, status: 400, reason: :http_error}

      assert Beat.failure_label({:model_request_failed, transient}) =~ "tras varios intentos"
      assert Beat.failure_label({:model_request_failed, rejected}) =~ "rechazó la petición"
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
