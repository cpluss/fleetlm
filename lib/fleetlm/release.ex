defmodule Fleetlm.Release do
  @moduledoc """
  Helpers invoked from CLI tasks in the release for database maintenance.
  """

  @app :fleetlm

  def migrate do
    load_app()

    repos()
    |> Enum.each(fn repo ->
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end)

    :ok
  end

  def rollback(repo, version) do
    load_app()

    repo = resolve_repo(repo)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, :down, to: version)
      end)

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp resolve_repo(repo) when is_atom(repo), do: repo

  defp resolve_repo(repo) when is_binary(repo) do
    repo |> String.to_existing_atom()
  end
end
