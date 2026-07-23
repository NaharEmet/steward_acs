defmodule Acs.Release do
  @moduledoc """
  Release tasks for running in production/releases.
  """
  require Logger

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def import_organizations do
    with_repo(fn -> Acs.Orgs.import_yaml() end)
  end

  def bootstrap_owner(email, organization_slug) do
    with_repo(fn -> Acs.Accounts.bootstrap_owner(email, organization_slug) end)
  end

  defp with_repo(fun) do
    load_app()

    {:ok, result, _apps} = Ecto.Migrator.with_repo(Acs.Repo, fn _repo -> fun.() end)
    result
  end

  defp repos do
    Application.fetch_env!(:steward_acs, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(:steward_acs)
  end
end
