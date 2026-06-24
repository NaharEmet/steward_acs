defmodule Acs.Cluster do
  @moduledoc """
  Cluster identity and filtering context.

  Each ACS instance belongs to a named cluster (e.g., "dev", "prod-us-east").
  All operations are scoped to the current cluster.

  Also provides `developer_name/0` to read the developer identity
  used for tagging memory creation.
  """

  @doc """
  Returns the current cluster name from config.
  Defaults to "default" if not configured.
  """
  def current do
    Application.get_env(:steward_acs, :cluster_name, "default")
  end

  @doc """
  Returns the list of all known clusters.
  Currently returns just the current cluster; future: configured list of peers.
  """
  def all do
    [current()]
  end

  @doc """
  Returns an Ecto query filter for the current cluster.

  ## Usage

      from t in Task, where: t.cluster == ^Cluster.filter()
  """
  def filter do
    current()
  end

  @doc """
  Returns the developer name from config.
  Set via ACS_DEVELOPER_NAME env var. Defaults to "unknown" if not configured.
  This identifies the human developer creating memories and actions.
  """
  def developer_name do
    Application.get_env(:steward_acs, :developer_name, "unknown")
  end
end
