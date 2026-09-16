defmodule Dragonex.ModelsProviderOrderTest do
  @moduledoc """
  OPENROUTER_PROVIDER_ORDER: el routing de upstream providers de OpenRouter.

  Cobra el parseo CSV, el gate por provider activo, el merge con el extra de
  reasoning y el cableado en los tres agentes del motor (DM ya lo recibía vía
  `bootstrap.ex`; PC bots y TurnMaster lo leen en `new`).
  """

  use ExUnit.Case, async: false

  alias Dragonex.{ModelConfig, Models, PCAgent, TurnMaster}

  # Env + ModelConfig son globales de nodo: snapshot/restore en cada test para
  # que estos knobs no se filtren al resto de la suite (el .env.dev del
  # usuario puede traer DRAGONEX_PROVIDER=seteado).
  setup do
    env = %{
      "DRAGONEX_PROVIDER" => System.get_env("DRAGONEX_PROVIDER"),
      "OPENROUTER_PROVIDER_ORDER" => System.get_env("OPENROUTER_PROVIDER_ORDER")
    }

    cfg = ModelConfig.get()
    ModelConfig.clear()

    # Hermético: el suite puede arrancar con .env.dev ya cargado por
    # runtime.exs (test_helper lo neutraliza, pero este archivo no debe
    # depender de eso). Los tests que asumen "nada seteado" parten de env
    # limpio; on_exit restaura el original.
    System.delete_env("DRAGONEX_PROVIDER")
    System.delete_env("OPENROUTER_PROVIDER_ORDER")

    on_exit(fn ->
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      restore_config(cfg)
    end)

    :ok
  end

  describe "parse_provider_order/1" do
    test "CSV con mezcla de casing y vacíos → slugs ordenados en minúscula" do
      assert Models.parse_provider_order("DeepInfra, Relace,,Wafer") ==
               ["deepinfra", "relace", "wafer"]
    end

    test "nil / vacío / solo espacios → []" do
      assert Models.parse_provider_order(nil) == []
      assert Models.parse_provider_order("") == []
      assert Models.parse_provider_order("  ") == []
    end
  end

  describe "openrouter_provider_extra/0" do
    test "con lista y provider openrouter → objeto provider con order y allow_fallbacks" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "DeepInfra, Relace,,Wafer")

      assert Models.openrouter_provider_extra() == %{
               "provider" => %{
                 "order" => ["deepinfra", "relace", "wafer"],
                 "allow_fallbacks" => true
               }
             }
    end

    test "env vacío/unset → nil (routing default de OpenRouter)" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "")

      assert Models.openrouter_provider_extra() == nil
    end

    test "provider opencode → nil aunque la lista esté seteada (OpenCode no lo entiende)" do
      System.put_env("DRAGONEX_PROVIDER", "opencode")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "deepinfra,relace")

      assert Models.openrouter_provider_extra() == nil
    end

    test "override runtime de provider a :openrouter gana sobre el env opencode" do
      System.put_env("DRAGONEX_PROVIDER", "opencode")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "deepinfra,relace")
      ModelConfig.set(provider: :openrouter)

      assert Models.openrouter_provider_extra() ==
               %{"provider" => %{"order" => ["deepinfra", "relace"], "allow_fallbacks" => true}}
    end
  end

  describe "request_extra/0" do
    test "fusiona reasoning + provider order cuando ambos están activos" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "deepinfra,relace")
      ModelConfig.set(reasoning: "high")

      assert Models.request_extra() == %{
               "reasoning" => %{"effort" => "high"},
               "provider" => %{"order" => ["deepinfra", "relace"], "allow_fallbacks" => true}
             }
    end

    test "sólo reasoning → sólo su clave" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      ModelConfig.set(reasoning: "low")

      assert Models.request_extra() == %{"reasoning" => %{"effort" => "low"}}
    end

    test "sólo provider order → sólo su clave" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "wafer")

      assert Models.request_extra() ==
               %{"provider" => %{"order" => ["wafer"], "allow_fallbacks" => true}}
    end

    test "nada seteado → nil (no se envía extra)" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")

      assert Models.request_extra() == nil
    end
  end

  describe "cableado en los agentes del motor" do
    test "PCAgent.new/3 mete el extra en ModelSettings cuando hay provider order" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "deepinfra,relace")

      character =
        Dragonex.Character.new(name: "Bot", race: "human", class: "fighter", level: 1)

      agent = PCAgent.new(%ExAgent.Models.Test{label: "pc"}, character)

      assert agent.settings.extra == %{
               "provider" => %{"order" => ["deepinfra", "relace"], "allow_fallbacks" => true}
             }

      assert agent.settings.max_tokens == 2048
    end

    test "TurnMaster.new/2 mete el extra en ModelSettings cuando hay provider order" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")
      System.put_env("OPENROUTER_PROVIDER_ORDER", "deepinfra")

      agent = TurnMaster.new(%ExAgent.Models.Test{label: "tm"})

      assert agent.settings.extra ==
               %{"provider" => %{"order" => ["deepinfra"], "allow_fallbacks" => true}}

      assert agent.settings.max_tokens == 256
    end

    test "sin provider order, los bots no envían extra" do
      System.put_env("DRAGONEX_PROVIDER", "openrouter")

      assert TurnMaster.new(%ExAgent.Models.Test{label: "tm"}).settings.extra == %{}
    end
  end

  defp restore_config(%ModelConfig{} = cfg) do
    ModelConfig.clear()

    fields =
      [provider: cfg.provider, model: cfg.model, reasoning: cfg.reasoning]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if fields != [], do: ModelConfig.set(fields)
  end
end
