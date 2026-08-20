defmodule Dragones.MixProject do
  use Mix.Project

  def project do
    [
      app: :dragones,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Dragones.Application, []}
    ]
  end

  defp deps do
    [
      local_dep(:exagent, "kukapu/exagent"),
      local_dep(:dic_ex, "kukapu/dic_ex"),
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:bcrypt_elixir, "~> 3.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:dotenvy, "~> 1.1", only: [:dev, :test]}
    ]
  end

  # Switch entre deps de GitHub (producción/CI) y deps locales (desarrollo).
  #
  # mix.exs se evalúa ANTES que config/runtime.exs, así que Dotenvy todavía no
  # ha cargado .env.dev: la variable debe venir del shell. Usa `bin/dev` o
  # exporta a mano: `DRAGONES_LOCAL_DEPS=1 mix phx.server`.
  #
  #   DRAGONES_LOCAL_DEPS=1            -> usa path local
  #   DRAGONES_DEPS_ROOT=../           -> raíz de los paquetes (default: ../)
  #
  # Cuando está activo, resuelve a:
  #   {:exagent, path: "../exagent"}   (y "../dic_ex")
  # Si la carpeta no existe, mix fallará con un error claro (mejor que caer
  # silenciosamente a GitHub mientras crees que estás probando local).
  defp local_dep(name, repo) do
    if System.get_env("DRAGONES_LOCAL_DEPS") == "1" do
      root = System.get_env("DRAGONES_DEPS_ROOT", "../")
      path = Path.join(root, Atom.to_string(name))

      unless File.dir?(path) do
        raise """
        DRAGONES_LOCAL_DEPS=1 pero no existe #{path}.
        Crea la carpeta o ajusta DRAGONES_DEPS_ROOT.
        """
      end

      {name, path: path}
    else
      {name, github: repo, branch: "main"}
    end
  end
end
