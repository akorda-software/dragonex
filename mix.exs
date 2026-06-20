defmodule Dragones.MixProject do
  use Mix.Project

  def project do
    [
      app: :dragones,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Dragones.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Path dep so we can fix exAgent friction in-place during the spike
      # (swap for {:exagent, "~> 1.0"} once stable).
      {:exagent, path: "../exAgent"},
      {:ecto, "~> 3.12"}
    ]
  end
end
