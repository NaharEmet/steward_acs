defmodule Acs.MCP.Tools.ClusterHandlersTest do
  use ExUnit.Case, async: false  # modifies app config

  alias Acs.MCP.Tools.ClusterHandlers

  setup do
    # Store original config
    orig_commands = Application.get_env(:steward_acs, :allowed_commands)
    orig_paths = Application.get_env(:steward_acs, :allowed_paths)

    on_exit(fn ->
      # Restore original config
      if orig_commands,
        do: Application.put_env(:steward_acs, :allowed_commands, orig_commands),
        else: Application.delete_env(:steward_acs, :allowed_commands)

      if orig_paths,
        do: Application.put_env(:steward_acs, :allowed_paths, orig_paths),
        else: Application.delete_env(:steward_acs, :allowed_paths)
    end)

    :ok
  end

  describe "exec_command/1" do
    test "rejects missing command" do
      assert {:error, "Missing required parameter: 'command'"} = ClusterHandlers.exec_command(%{})
    end

    test "rejects disallowed command" do
      Application.put_env(:steward_acs, :allowed_commands, ["echo", "ls"])
      assert {:error, msg} = ClusterHandlers.exec_command(%{"command" => "rm"})
      assert msg =~ "not in allowed list"
    end

    test "rejects disallowed working directory" do
      Application.put_env(:steward_acs, :allowed_commands, ["echo"])
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.exec_command(%{"command" => "echo", "cwd" => "/etc"})
      assert msg =~ "not in allowed paths"
    end

    test "rejects arguments with shell metacharacters" do
      Application.put_env(:steward_acs, :allowed_commands, ["echo"])
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.exec_command(%{
        "command" => "echo", "args" => ["hello; rm -rf /"], "cwd" => "/tmp"
      })
      assert msg =~ "shell metacharacters"
    end

    test "executes allowed command and returns output" do
      Application.put_env(:steward_acs, :allowed_commands, ~w(echo ls cat))
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])

      assert {:ok, result} = ClusterHandlers.exec_command(%{
        "command" => "echo",
        "args" => ["hello world"],
        "cwd" => "/tmp"
      })
      assert result.stdout =~ "hello world"
      assert result.exit_code == 0
    end

    test "returns error for unknown command" do
      Application.put_env(:steward_acs, :allowed_commands, ~w(nonexistent_cmd_xyz))
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])
      assert {:error, msg} = ClusterHandlers.exec_command(%{
        "command" => "nonexistent_cmd_xyz",
        "args" => [],
        "cwd" => "/tmp"
      })
      assert msg =~ "not found in PATH" or msg =~ "no such file"
    end

    test "captures multi-line output" do
      Application.put_env(:steward_acs, :allowed_commands, ~w(ls))
      Application.put_env(:steward_acs, :allowed_paths, ["/tmp"])

      assert {:ok, result} = ClusterHandlers.exec_command(%{
        "command" => "ls",
        "args" => ["-la", "/tmp"],
        "cwd" => "/tmp"
      })
      assert String.contains?(result.stdout, "total") or String.length(result.stdout) > 0
      assert result.exit_code == 0
    end
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

        # Read it back
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
