defmodule Acs.MCP.Tools.DynamicToolsTest do
  use ExUnit.Case, async: false

  setup do
    tmp_dir =
      Path.expand("../../../tmp/dynamic_tools_#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(tmp_dir)

    # Clean up any stale test files from previous runs
    default_path =
      Path.expand(
        "../../../acs/acstools",
        Application.app_dir(:steward_acs)
      )

    stale = Path.join(default_path, "my-custom-tool.yaml")
    if File.exists?(stale), do: File.rm!(stale)

    orig_env = System.get_env("MCP_TOOLS_PATH")
    System.put_env("MCP_TOOLS_PATH", tmp_dir)

    on_exit(fn ->
      if orig_env,
        do: System.put_env("MCP_TOOLS_PATH", orig_env),
        else: System.delete_env("MCP_TOOLS_PATH")

      File.rm_rf!(tmp_dir)

      # Force refresh to clear any loaded state from test files
      Acs.MCP.ToolRegistry.refresh()
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp valid_write_args(overrides \\ []) do
    Map.merge(
      %{
        "name" => "my-custom-tool",
        "description" => "A custom test tool created by write_tool",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "param1" => %{"type" => "string", "description" => "A test parameter"}
          },
          "required" => ["param1"]
        },
        "endpoint" => "http://my-service:8080/tool"
      },
      Map.new(overrides)
    )
  end

  describe "write_tool" do
    test "writes valid tool YAML and refreshes", %{tmp_dir: tmp_dir} do
      args = valid_write_args()

      assert {:ok, result} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)
      assert result.tool == "my-custom-tool"
      assert result.reloaded == true
      assert String.contains?(result.path, tmp_dir)

      # Verify file exists at expected path
      file_path = Path.join(tmp_dir, "my-custom-tool.yaml")
      assert File.exists?(file_path)

      # Verify file is valid YAML matching ToolLoader expectations
      assert {:ok, config} = YamlElixir.read_from_file(file_path)
      assert config["app"] == "custom"
      assert config["base_url"] == "http://my-service:8080"
      assert config["prefix"] == false
      assert length(config["tools"]) == 1

      tool = hd(config["tools"])
      assert tool["name"] == "my-custom-tool"
      assert tool["description"] == "A custom test tool created by write_tool"
      assert tool["level"] == 1
      assert tool["role"] == "collaborator"
      assert tool["category"] == "custom"
      assert tool["endpoint"] == "/tool"

      # Verify input_schema is preserved
      assert is_map(tool["input_schema"])
      assert tool["input_schema"]["type"] == "object"
    end

    test "writes to correct path with default fallback" do
      orig_env = System.get_env("MCP_TOOLS_PATH")
      System.delete_env("MCP_TOOLS_PATH")

      args = valid_write_args()
      {:ok, result} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)

      assert String.contains?(result.path, "acstools")

      # Cleanup immediately to minimize pollution
      if File.exists?(result.path), do: File.rm!(result.path)
      if orig_env, do: System.put_env("MCP_TOOLS_PATH", orig_env)
    end

    test "returns error for missing name" do
      args = valid_write_args(%{"name" => nil})
      assert {:error, _} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)

      args2 = valid_write_args(%{"name" => ""})
      assert {:error, _} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args2)

      args3 = Map.delete(valid_write_args(), "name")
      assert {:error, _} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args3)
    end

    test "returns error for missing description" do
      args = Map.delete(valid_write_args(), "description")
      assert {:error, _} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)
    end

    test "returns error for missing inputSchema" do
      args = Map.delete(valid_write_args(), "inputSchema")
      assert {:error, _} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)
    end

    test "returns error when both handler and endpoint are missing" do
      args =
        valid_write_args()
        |> Map.delete("endpoint")

      assert {:error, _} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)
    end

    test "accepts endpoint as path with separate base_url", %{tmp_dir: tmp_dir} do
      args =
        valid_write_args(%{
          "endpoint" => "/api/custom",
          "base_url" => "http://my-api:4000"
        })

      assert {:ok, result} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)
      assert result.reloaded == true

      file_path = Path.join(tmp_dir, "my-custom-tool.yaml")
      assert {:ok, config} = YamlElixir.read_from_file(file_path)
      assert config["base_url"] == "http://my-api:4000"
      assert hd(config["tools"])["endpoint"] == "/api/custom"
    end

    test "written file is valid YAML and passes ToolLoader validation", %{tmp_dir: tmp_dir} do
      args = valid_write_args()
      {:ok, _result} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)

      tool_file = Path.join(tmp_dir, "my-custom-tool.yaml")

      # Parse and validate using the same validation as ToolLoader
      assert {:ok, config} = YamlElixir.read_from_file(tool_file)
      assert :ok = Acs.MCP.ToolLoader.validate_config(config)
    end

    test "tool appears in registry after write and refresh" do
      args = valid_write_args()
      {:ok, _result} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)

      # After refresh, the tool should be discoverable
      tools = Acs.MCP.ToolRegistry.list_tools()
      names = Enum.map(tools, & &1["name"])
      assert "my-custom-tool" in names
    end

    test "preserves handler field when provided", %{tmp_dir: tmp_dir} do
      args =
        valid_write_args(%{
          "handler" => "MyCustomModule",
          "endpoint" => nil
        })

      assert {:ok, result} = Acs.MCP.Tools.DynamicTools.call_tool("write_tool", args)
      assert result.reloaded == true

      file_path = Path.join(tmp_dir, "my-custom-tool.yaml")
      assert {:ok, config} = YamlElixir.read_from_file(file_path)

      tool = hd(config["tools"])
      assert tool["handler"] == "MyCustomModule"
      # No endpoint key should exist for handler-only tools
      refute Map.has_key?(tool, "endpoint")
    end
  end

  describe "split_endpoint_url" do
    test "parses full HTTP URL" do
      assert {:ok, "http://service:8080", "/tool"} =
               Acs.MCP.Tools.DynamicTools.split_endpoint_url("http://service:8080/tool")
    end

    test "parses full HTTPS URL without port" do
      assert {:ok, "https://api.example.com", "/v1/endpoint"} =
               Acs.MCP.Tools.DynamicTools.split_endpoint_url(
                 "https://api.example.com/v1/endpoint"
               )
    end

    test "returns :error for path-only URL" do
      assert :error = Acs.MCP.Tools.DynamicTools.split_endpoint_url("/api/tool")
    end

    test "returns :error for invalid URL" do
      assert :error = Acs.MCP.Tools.DynamicTools.split_endpoint_url("not-a-url")
    end
  end
end
