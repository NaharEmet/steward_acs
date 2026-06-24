defmodule Acs.ClusterTest do
  use ExUnit.Case, async: false

  describe "current/0" do
    test "returns configured cluster name" do
      Application.put_env(:steward_acs, :cluster_name, "test-cluster")
      assert Acs.Cluster.current() == "test-cluster"
    after
      Application.put_env(:steward_acs, :cluster_name, "default")
    end

    test "defaults to 'default'" do
      Application.delete_env(:steward_acs, :cluster_name)
      assert Acs.Cluster.current() == "default"
    after
      Application.put_env(:steward_acs, :cluster_name, "default")
    end
  end

  describe "all/0" do
    test "returns list with current cluster" do
      Application.put_env(:steward_acs, :cluster_name, "dev")
      assert Acs.Cluster.all() == ["dev"]
    after
      Application.put_env(:steward_acs, :cluster_name, "default")
    end
  end

  describe "filter/0" do
    test "returns current cluster for query filtering" do
      Application.put_env(:steward_acs, :cluster_name, "prod")
      assert Acs.Cluster.filter() == "prod"
    after
      Application.put_env(:steward_acs, :cluster_name, "default")
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
