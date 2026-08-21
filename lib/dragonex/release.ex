defmodule Dragonex.Release do
  @moduledoc """
  Tareas de release para producción (sin Mix disponible).

      bin/dragonex eval "Dragonex.Release.migrate()"
      bin/dragonex eval "Dragonex.Release.rollback(Dragonex.Repo, 0)"
  """

  @app :dragonex

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
