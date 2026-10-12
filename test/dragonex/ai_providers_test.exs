defmodule Dragonex.AIProvidersTest do
  @moduledoc """
  Who pays for a table's AI (D242): players' own providers, the fixed house
  model with its cheapest routing, and the per-game choice in `games.ai`.
  Provider HTTP is stubbed through `config :dragonex, :ai_http`.
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, AIProviders, GameAI, Models}

  @routing_key {Models, :house_routing}
  @catalogue_key {Models, :catalogue, "https://openrouter.ai/api/v1"}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    test_pid = self()
    Application.put_env(:dragonex, :ai_http, plug: &stub(&1, test_pid))

    old_env = Map.new(~w(OPENROUTER_API_KEY DRAGONEX_SERVER_MODELS), &{&1, System.get_env(&1)})
    old_terms = Map.new([@routing_key, @catalogue_key], &{&1, :persistent_term.get(&1, :missing)})

    on_exit(fn ->
      Application.delete_env(:dragonex, :ai_http)

      Enum.each(old_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      Enum.each(old_terms, fn
        {key, :missing} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)
    end)

    :ok
  end

  describe "list_models/2" do
    test "OpenAI keeps chat models only and sends the key as a bearer" do
      assert {:ok, models} = AIProviders.list_models("openai", "sk-openai")
      assert Enum.map(models, & &1.id) == ["gpt-5-mini", "o4-mini"]
      assert_received {:request, "GET", "/v1/models", %{"authorization" => "Bearer sk-openai"}}
    end

    test "Google strips the models/ prefix and drops non-chat Gemini" do
      assert {:ok, models} = AIProviders.list_models("google", "g-key")
      assert Enum.map(models, & &1.id) == ["gemini-2.5-flash"]
    end

    test "Anthropic authenticates with x-api-key and its version header" do
      assert {:ok, [%{id: "claude-haiku-4-5"}]} = AIProviders.list_models("anthropic", "ak")
      assert_received {:request, "GET", "/v1/models", headers}
      assert headers["x-api-key"] == "ak"
      assert headers["anthropic-version"] == "2023-06-01"
    end

    test "OpenRouter checks the key, then keeps models that can run without reasoning" do
      assert {:ok, models} = AIProviders.list_models("openrouter", "or-key")
      assert Enum.map(models, & &1.id) == ["deepseek/deepseek-v4.1-flash", "plain/model"]
      assert_received {:request, "GET", "/api/v1/key", _}
    end

    test "a rejected key, a provider error and an unknown provider" do
      assert AIProviders.list_models("openrouter", "bad") == {:error, :unauthorized}
      assert AIProviders.list_models("opencode", "bad") == {:error, :unauthorized}
      assert AIProviders.list_models("opencode", "boom") == {:error, {:http, 500}}
      assert AIProviders.list_models("acme", "key") == {:error, :unknown_provider}
    end
  end

  describe "model/4" do
    test "compatible providers run on their OpenAI Chat endpoint without reasoning" do
      model = AIProviders.model("anthropic", "claude-haiku-4-5", "ak", nil)
      assert model.base_url == "https://api.anthropic.com/v1"
      assert model.tool_profile == :chat_tools_v1
      assert model.model.provider == :openai
      assert model.api_key == "ak"
      refute inspect(model) =~ "ak\""
    end

    test "OpenRouter keeps its own profile and default routing" do
      metadata = %{"supported_parameters" => ["tools"]}
      model = AIProviders.model("openrouter", "plain/model", "or-key", metadata)
      assert model.tool_profile == :openrouter_chat_tools_v1
      assert model.provider_options[:openrouter_provider] == %{}
    end
  end

  describe "house model" do
    test "endpoints are ranked by what our turns cost, tools only" do
      endpoints = [
        endpoint("cheap-prompt", "0.10", "2.00", nil),
        endpoint("cached", "0.30", "1.00", "0.03"),
        endpoint("no-tools", "0.01", "0.01", "0.001", ["max_tokens"]),
        Map.put(endpoint("down", "0.01", "0.01", "0.001"), "status", -1),
        endpoint("mid", "0.20", "0.50", "0.05")
      ]

      # Weighted: mid 0.0965, cached 0.1201, cheap-prompt 0.176 (no cache price).
      assert Models.rank_endpoints(endpoints) == ["mid", "cached", "cheap-prompt"]
    end

    test "production plays every role with the house model on the ranked routing" do
      System.put_env("OPENROUTER_API_KEY", "server-key")
      System.put_env("DRAGONEX_SERVER_MODELS", "fixed")
      :persistent_term.erase(@routing_key)
      :persistent_term.erase(@catalogue_key)

      models = Models.house_models()
      assert models[:model] == models[:summarizer]
      assert models[:model] == models[:turnmaster_model]
      assert models[:model].model.id == "deepseek/deepseek-v4.1-flash"

      assert models[:model].provider_options[:openrouter_provider] == %{
               order: ["morph", "decart"],
               allow_fallbacks: true,
               require_parameters: true
             }

      # The ranking is cached: a second table does not ask again.
      flush_requests()
      Models.house_routing()
      refute_received {:request, _, "/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints", _}
    end

    test "without a server key the house falls back to the offline models" do
      System.put_env("OPENROUTER_API_KEY", "")
      assert Models.house_models() == []
    end
  end

  describe "GameAI" do
    setup do
      {:ok, user} =
        Accounts.register(%{
          email: "ai-#{Ecto.UUID.generate()}@dragonex.test",
          password: "password123",
          display_name: "Paga"
        })

      %{user: user}
    end

    test "an own key builds every role on the player's provider", %{user: user} do
      :ok = Accounts.put_api_key(user, "openai", "sk-player-key-9999")
      game = %{user_id: user.id, ai: own("openai", "gpt-5-mini")}

      models = GameAI.models(game)
      assert models[:model].api_key == "sk-player-key-9999"
      assert models[:model].model.id == "gpt-5-mini"
      assert models[:summarizer] == models[:model]
      assert GameAI.label(game) == "OpenAI · gpt-5-mini"
    end

    test "a removed key falls back to the house", %{user: user} do
      System.put_env("DRAGONEX_SERVER_MODELS", "open")
      game = %{user_id: user.id, ai: own("openai", "gpt-5-mini")}
      assert GameAI.models(game) == []
    end

    test "server models are a dev-only choice" do
      ai = %{"source" => "server", "provider" => "openrouter", "model" => "x/y"}

      System.put_env("DRAGONEX_SERVER_MODELS", "open")

      assert GameAI.selection(%{ai: ai}) == %{
               source: :server,
               provider: "openrouter",
               model: "x/y"
             }

      System.put_env("DRAGONEX_SERVER_MODELS", "fixed")
      assert GameAI.selection(%{ai: ai}) == %{source: :house}
      assert GameAI.label(%{ai: ai}) == "deepseek/deepseek-v4.1-flash"
    end

    test "selections survive the jsonb round trip" do
      for s <- [
            %{source: :house},
            %{source: :own, provider: "google", model: "gemini-2.5-flash", metadata: nil}
          ] do
        assert GameAI.selection(%{ai: GameAI.encode(s)}) == s
      end

      assert GameAI.selection(%{ai: %{}}) == %{source: :house}
      assert GameAI.selection(%{ai: %{"source" => "own"}}) == %{source: :house}
    end
  end

  defp own(provider, model),
    do: %{"source" => "own", "provider" => provider, "model" => model, "metadata" => nil}

  defp endpoint(tag, prompt, completion, cached, params \\ ["tools", "max_tokens"]) do
    pricing = %{"prompt" => prompt, "completion" => completion}
    pricing = if cached, do: Map.put(pricing, "input_cache_read", cached), else: pricing
    %{"tag" => tag, "status" => 0, "supported_parameters" => params, "pricing" => pricing}
  end

  defp flush_requests do
    receive do
      {:request, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  defp stub(conn, test_pid) do
    headers = Map.new(conn.req_headers)
    send(test_pid, {:request, conn.method, conn.request_path, headers})
    auth = headers["authorization"] || headers["x-api-key"]

    case {conn.host, conn.request_path, auth} do
      {_, _, "Bearer bad"} ->
        Plug.Conn.send_resp(conn, 401, "")

      {_, _, "Bearer boom"} ->
        Plug.Conn.send_resp(conn, 500, "")

      {"api.openai.com", "/v1/models", _} ->
        data(conn, ~w(gpt-5-mini o4-mini text-embedding-3-small gpt-4o-realtime-preview dall-e-3))

      {"generativelanguage.googleapis.com", _, _} ->
        data(conn, ~w(models/gemini-2.5-flash models/gemini-embedding-001 models/imagen-4))

      {"api.anthropic.com", "/v1/models", _} ->
        data(conn, ~w(claude-haiku-4-5))

      {"openrouter.ai", "/api/v1/key", _} ->
        Req.Test.json(conn, %{"data" => %{"label" => "k"}})

      {"openrouter.ai", "/api/v1/models", _} ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => "plain/model", "supported_parameters" => ["tools"]},
            %{
              "id" => "deepseek/deepseek-v4.1-flash",
              "supported_parameters" => ["tools", "reasoning", "reasoning_effort"],
              "reasoning" => %{"mandatory" => false}
            },
            %{
              "id" => "always/thinks",
              "supported_parameters" => ["tools", "reasoning"],
              "reasoning" => %{"mandatory" => true}
            },
            %{"id" => "no/tools", "supported_parameters" => ["max_tokens"]}
          ]
        })

      {"openrouter.ai", "/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints", _} ->
        Req.Test.json(conn, %{
          "data" => %{
            "endpoints" => [
              endpoint("decart", "0.20", "0.80", "0.02"),
              endpoint("morph", "0.15", "0.60", "0.015")
            ]
          }
        })

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp data(conn, ids), do: Req.Test.json(conn, %{"data" => Enum.map(ids, &%{"id" => &1})})
end
