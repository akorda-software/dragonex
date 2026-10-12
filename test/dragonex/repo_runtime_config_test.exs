defmodule Dragonex.RepoRuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    environment = System.get_env()
    System.delete_env("DB_TEST_NAME")

    on_exit(fn ->
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(environment, &1))
      |> Enum.each(&System.delete_env/1)

      System.put_env(environment)
    end)

    :ok
  end

  test "test runtime ignores the development database even when DB_NAME is inherited" do
    System.put_env("DB_NAME", "dragonex_quality_dev")
    assert database(:test) == "dragonex_test"
  end

  test "a custom test database uses its own explicit setting" do
    System.put_env("DB_NAME", "dragonex_quality_dev")
    System.put_env("DB_TEST_NAME", "dragonex_quality_test")
    assert database(:test) == "dragonex_quality_test"
  end

  test "development keeps DB_NAME and ignores the test-only override" do
    System.put_env("DB_NAME", "dragonex_quality_dev")
    System.put_env("DB_TEST_NAME", "dragonex_quality_test")
    assert database(:dev) == "dragonex_quality_dev"
  end

  defp database(env) do
    @runtime
    |> Config.Reader.read!(env: env, target: :host)
    |> Keyword.fetch!(:dragonex)
    |> Keyword.fetch!(Dragonex.Repo)
    |> Keyword.fetch!(:database)
  end
end
