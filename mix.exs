defmodule Dragonex.MixProject do
  use Mix.Project

  def project do
    [
      app: :dragonex,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # Local packages gain new protocol implementations during code reload.
      # A consolidated dispatch table would keep ignoring those implementations.
      consolidate_protocols: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      lockfile: if(hex_dependencies?(), do: "mix.hex.lock", else: "mix.lock"),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Dragonex.Application, []}
    ]
  end

  defp deps do
    [
      workspace_dep(:exagent, "exAgent", "~> 2.2.2"),
      workspace_dep(:dic_ex, "dic_ex", "~> 0.3"),
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:bandit, "~> 1.13"},
      {:jason, "~> 1.4"},
      {:bcrypt_elixir, "~> 3.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:dotenvy, "~> 1.1"},
      {:gettext, "~> 0.26"}
    ]
  end

  # Dev siempre usa los hermanos, incluso con `mix` directamente. Producción
  # siempre usa Hex. Test permite comprobar ese segundo grafo explícitamente.
  # Las rutas se anclan al repo, no al cwd del shell. En Linux exAgent lleva A.
  defp workspace_dep(name, directory, requirement) do
    if hex_dependencies?() do
      {name, requirement}
    else
      root = System.get_env("DRAGONEX_DEPS_ROOT", "..") |> Path.expand(__DIR__)
      path = Path.join(root, directory)

      unless File.regular?(Path.join(path, "mix.exs")) do
        raise "Falta la dependencia local #{name} en #{path}. Ajusta DRAGONEX_DEPS_ROOT."
      end

      {name, path: path}
    end
  end

  defp hex_dependencies? do
    Mix.env() == :prod or
      (Mix.env() == :test and System.get_env("DRAGONEX_DEPS_SOURCE") == "hex")
  end
end
