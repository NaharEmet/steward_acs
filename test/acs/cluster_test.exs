defmodule Acs.ClusterTest do
  use ExUnit.Case, async: false

  describe "current/0" do
    test "returns configured cluster name" do
      Application.put_env(:steward_acs, :org_name, "test-cluster")
      assert Acs.Cluster.current() == "test-cluster"
    after
      Application.delete_env(:steward_acs, :org_name)
    end

    test "defaults to 'default'" do
      Application.delete_env(:steward_acs, :org_name)
      Application.delete_env(:steward_acs, :cluster_name)
      assert Acs.Cluster.current() == "default"
    after
      Application.delete_env(:steward_acs, :org_name)
      Application.delete_env(:steward_acs, :cluster_name)
    end
  end

  describe "all/0" do
    test "returns list with current cluster" do
      Application.put_env(:steward_acs, :org_name, "dev")
      assert Acs.Cluster.all() == ["dev"]
    after
      Application.delete_env(:steward_acs, :org_name)
    end
  end

  describe "filter/0" do
    test "returns current cluster for query filtering" do
      Application.put_env(:steward_acs, :org_name, "prod")
      assert Acs.Cluster.filter() == "prod"
    after
      Application.delete_env(:steward_acs, :org_name)
    end
  end

  describe "developer_name/0" do
    test "returns configured developer name" do
      Application.put_env(:steward_acs, :developer_name, "Alice")
      assert Acs.Cluster.developer_name() == "Alice"
    after
      Application.put_env(:steward_acs, :developer_name, "unknown")
    end

    test "defaults to 'unknown'" do
      Application.delete_env(:steward_acs, :developer_name)
      assert Acs.Cluster.developer_name() == "unknown"
    after
      Application.put_env(:steward_acs, :developer_name, "unknown")
    end
  end
end
