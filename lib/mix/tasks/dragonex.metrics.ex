defmodule Mix.Tasks.Dragonex.Metrics do
  @shortdoc "Métricas de calidad (fallos, latencia, tiradas) de partidas guardadas"
  @moduledoc """
  Calcula `Dragonex.Playtest.Metrics` sobre partidas de la DB.

      bin/dev dragonex.metrics 19451 19453     # partidas concretas
      bin/dev dragonex.metrics --last 10       # las 10 más recientes con eventos
      bin/dev dragonex.metrics --since 19440   # desde un id

  Solo lee: arranca el Repo, no el `Game` ni el endpoint.
  """

  use Mix.Task

  import Ecto.Query

  alias Dragonex.Games.{Game, GameEvent, Participant}
  alias Dragonex.Playtest.Metrics
  alias Dragonex.Repo

  @impl true
  def run(argv) do
    {opts, ids, _} = OptionParser.parse(argv, strict: [last: :integer, since: :integer])

    Mix.Task.run("app.config")
    Logger.configure(level: :info)
    {:ok, _} = Application.ensure_all_started([:ecto_sql, :postgrex])
    {:ok, _} = Repo.start_link(pool_size: 2)

    game_ids = select_games(Enum.map(ids, &String.to_integer/1), opts)

    if game_ids == [] do
      Mix.shell().info("No hay partidas que analizar.")
    else
      report(game_ids)
    end
  end

  @doc false
  def report(game_ids) do
    results =
      for id <- game_ids do
        result = analyze(id)
        Mix.shell().info("Partida #{id}\n" <> Metrics.format(result))
        result
      end

    if length(results) > 1 do
      Mix.shell().info(
        "Total (#{length(results)} partidas)\n" <> Metrics.format(Metrics.merge(results))
      )
    end

    results
  end

  @doc "Analiza una partida guardada."
  def analyze(game_id) do
    events = Repo.all(from(e in GameEvent, where: e.game_id == ^game_id, order_by: e.seq))

    humans =
      Repo.all(
        from(p in Participant,
          where: p.game_id == ^game_id and p.kind == :human,
          select: p.name
        )
      )

    Metrics.analyze(events, humans)
  end

  defp select_games([_ | _] = ids, _opts), do: ids

  defp select_games([], opts) do
    with_events = from(e in GameEvent, select: e.game_id, distinct: true)

    query =
      from(g in Game, where: g.id in subquery(with_events), order_by: [desc: g.id], select: g.id)

    query = if since = opts[:since], do: where(query, [g], g.id >= ^since), else: query
    query = limit(query, ^Keyword.get(opts, :last, 10))
    query |> Repo.all() |> Enum.reverse()
  end
end
