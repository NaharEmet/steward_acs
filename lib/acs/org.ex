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
  def current do
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
  def from_subdomain(nil), do: "default"
  def from_subdomain(""), do: "default"
  def from_subdomain("www"), do: "default"
  def from_subdomain(subdomain), do: subdomain

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
