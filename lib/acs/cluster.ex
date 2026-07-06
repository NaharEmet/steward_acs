defmodule Acs.Cluster do
  @moduledoc """
  DEPRECATED: Use `Acs.Org` instead.

  Delegates all functions to `Acs.Org` for backward compatibility.
  Will be removed in a future release.
  """

  def current, do: Acs.Org.current()
  def all, do: Acs.Org.all()
  def filter, do: Acs.Org.filter()
  def developer_name, do: Acs.Org.developer_name()
  def project_name, do: Acs.Org.project_name()
end
