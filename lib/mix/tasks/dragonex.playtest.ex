defmodule Mix.Tasks.Dragonex.Playtest do
  @shortdoc "Juega partidas sin interfaz con el modelo real y mide su calidad"
  @moduledoc """
  Juega una o varias partidas con `Dragonex.Playtest` (jugador humano bot +
  compañeros IA contra el proveedor configurado) e imprime sus métricas.

      bin/dev dragonex.playtest                          # 1 partida del molino, es
      bin/dev dragonex.playtest --games 3 --turns 10
      bin/dev dragonex.playtest --scenario tavern --locale en --minutes 20

  Opciones: `--games` (1), `--turns` declaraciones humanas por partida (8),
  `--minutes` tope por partida (15), `--scenario` (`mill` o una clave de
  `Dragonex.Scenarios`), `--locale` (`es`/`en`), `--hero` (`fighter`),
  `--max-resumes` (3), `--quiet` (sin transcripción).

  **Gasta tokens del proveedor.** Sin API key se niega a jugar: los beats
  usarían `TestModel` y las métricas no significarían nada.
  """

  use Mix.Task

  alias Dragonex.Playtest
  alias Dragonex.Playtest.Metrics

  @switches [
    games: :integer,
    turns: :integer,
    minutes: :float,
    scenario: :string,
    locale: :string,
    hero: :string,
    max_resumes: :integer,
    quiet: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    unless Dragonex.Models.live?(Dragonex.Models.dm()) do
      Mix.raise(
        "No hay proveedor real configurado (falta la API key): el playtest no mediría nada."
      )
    end

    locale = if opts[:locale] == "en", do: :en, else: :es
    quiet? = Keyword.get(opts, :quiet, false)

    run_opts =
      [
        locale: locale,
        scenario: opts[:scenario] || "mill",
        hero: opts[:hero] || "fighter",
        turns: opts[:turns] || 8,
        minutes: opts[:minutes] || 15,
        max_resumes: opts[:max_resumes] || 3,
        on_event: if(quiet?, do: fn _ -> :ok end, else: &print_event/1)
      ]

    results =
      for i <- 1..Keyword.get(opts, :games, 1) do
        Mix.shell().info("\n=== Playtest #{i} ===")
        result = Playtest.run(run_opts)

        Mix.shell().info(
          "Partida #{result.game_id} · parada: #{inspect(result.stop)} · declaraciones #{result.declarations} · reanudaciones #{result.resumes}\n" <>
            Metrics.format(result.metrics)
        )

        result
      end

    if length(results) > 1 do
      merged = results |> Enum.map(& &1.metrics) |> Metrics.merge()

      Mix.shell().info(
        "\n=== Total (#{length(results)} partidas) ===\n" <> Metrics.format(merged)
      )
    end
  end

  defp print_event({:declare, who, text}), do: Mix.shell().info("  > #{who}: #{text}")

  defp print_event({:resume, n}),
    do: Mix.shell().info("  ⏸ mesa en pausa por fallo → reanudación #{n}")

  defp print_event(_), do: :ok
end
