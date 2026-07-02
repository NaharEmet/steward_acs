defmodule Acs.MCP.Tools.ClusterHandlersTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.Tools.ClusterHandlers

  setup do
    orig_paths = Application.get_env(:steward_acs, :allowed_paths)

    on_exit(fn ->
      if orig_paths,
        do: Application.put_env(:steward_acs, :allowed_paths, orig_paths),
        else: Application.delete_env(:steward_acs, :allowed_paths)
    end)

    :ok
  end

  describe "read_file/1" do
    test "rejects missing path" do
      assert {:error, "Missing required parameter: 'path'"} = ClusterHandlers.read_file(%{})
    end

    test "rejects path not in allowed paths" do
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.read_file(%{"path" => "/etc/passwd"})
      assert msg =~ "not in allowed paths"
    end

    test "rejects path prefix bypass (/tmp_extra)" do
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.read_file(%{"path" => "/tmp_extra/secret"})
      assert msg =~ "not in allowed paths"
    end

    test "returns error for non-existent file" do
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, _} = ClusterHandlers.read_file(%{"path" => "/tmp/nonexistent_xyz_file"})
    end
  end

  describe "write_file/1" do
    test "rejects missing parameters" do
      assert {:error, msg} = ClusterHandlers.write_file(%{"path" => "/tmp/test.txt"})
      assert msg =~ "Missing required parameters"
    end

    test "rejects path not in allowed paths" do
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.write_file(%{"path" => "/etc/hosts", "content" => "test"})
      assert msg =~ "not in allowed paths"
    end

    test "writes and reads back file" do
      test_path = "/tmp/acs_test_write_#{System.unique_integer([:positive])}.txt"
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])

      try do
        assert {:ok, result} = ClusterHandlers.write_file(%{"path" => test_path, "content" => "hello from test"})
        assert result.status == "written"

        assert {:ok, read_result} = ClusterHandlers.read_file(%{"path" => test_path})
        assert read_result.content == "hello from test"
      after
        File.rm(test_path)
      end
    end
  end

  describe "read_dir/1" do
    test "rejects missing path" do
      assert {:error, "Missing required parameter: 'path'"} = ClusterHandlers.read_dir(%{})
    end

    test "rejects path not in allowed paths" do
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.read_dir(%{"path" => "/etc"})
      assert msg =~ "not in allowed paths"
    end

    test "lists directory contents" do
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:ok, result} = ClusterHandlers.read_dir(%{"path" => "/tmp"})
      assert result.path == "/tmp"
      assert is_integer(result.count)
      assert is_list(result.entries)
    end
  end
end
