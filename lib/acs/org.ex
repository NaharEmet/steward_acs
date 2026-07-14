defmodule Acs.Org do
  @moduledoc """
  Org identity and filtering context for multi-tenancy.

  Each ACS instance belongs to an org, scoped via subdomain.
  All operations are scoped to the current org.

  Replaces `Acs.Cluster` (which now delegates here for backward compat).
  """

  @doc """
  Returns the current org name from config.
  Checks `:org_name` first, falls back to `:cluster_name`, defaults to "default".
  """
  @process_key {__MODULE__, :current_org}

  def current do
    Process.get(@process_key) || configured()
  end

  @doc """
  Runs `fun` with a request-local organization context.

  The context lives in the calling process and is restored afterwards, so
  concurrent requests for different organizations cannot overwrite global
  application configuration.
  """
  def put_current(org) when is_binary(org) and org != "" do
    Process.put(@process_key, org)
    :ok
  end

  def with_current(org, fun) when is_binary(org) and org != "" and is_function(fun, 0) do
    previous = Process.get(@process_key)
    put_current(org)

    try do
      fun.()
    after
      if previous, do: Process.put(@process_key, previous), else: Process.delete(@process_key)
    end
  end

  def configured do
    Application.get_env(:steward_acs, :org_name) ||
      Application.get_env(:steward_acs, :cluster_name, "default")
  end

  @doc """
  Returns the list of all known orgs.
  Currently returns just the current org.
  """
  def all do
    [current()]
  end

  @doc """
  Returns an Ecto query filter for the current org.

  ## Usage

      from t in Task, where: t.org == ^Org.filter()
  """
  def filter do
    current()
  end

  @doc """
  Resolves an org slug from a subdomain string.

  If the subdomain is nil/empty/"www", returns "default".
  Otherwise the subdomain is used directly as the org slug.
  Future: lookup from `orgs` table.
  """
  def from_subdomain(nil), do: configured()
  def from_subdomain(""), do: configured()
  def from_subdomain("www"), do: configured()

  def from_subdomain(subdomain) when is_binary(subdomain) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, subdomain),
      do: subdomain,
      else: configured()
  end

  @doc """
  Returns the developer name from config.
  """
  def developer_name do
    Application.get_env(:steward_acs, :developer_name, "unknown")
  end

  @doc """
  Returns the project name from config.
  """
  def project_name do
    Application.get_env(:steward_acs, :project_name, "")
  end
end
