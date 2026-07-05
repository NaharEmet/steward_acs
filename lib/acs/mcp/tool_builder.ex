defmodule Acs.MCP.ToolBuilder do
  @moduledoc """
  Declarative macro for defining MCP tools.

  ## Usage

      defmodule MyTools do
        use Acs.MCP.ToolBuilder

        declare :send_message,
          description: "Send a message to an actor",
          params: [:org_id, :actor_id, :content],
          required: [:org_id, :content],
          handler: {__MODULE__, :handle_send_message}

        declare :get_workflow,
          description: "Get workflow details",
          params: [:workflow_id, :org_id],
          handler: :get_workflow  # Short form - function name as atom
      end

  """

  @doc """
  Generates tool definitions for list_tools/0.
  """
  defmacro __using__(_opts) do
    quote do
      import Acs.MCP.ToolBuilder, only: [declare: 2]
      @tools_decls []
    end
  end

  @doc """
  Declare a tool with name, description, params, and handler.

  Options:
    - `:description` - Human-readable description
    - `:params` - Map of parameter name => schema (or list of param names for simple tools)
    - `:required` - List of required parameter names
    - `:handler` - `{Module, :function}` tuple or just `:function_name` atom
  """
  defmacro declare(name, opts) do
    quote do
      @tools_decls [{unquote(name), unquote(opts)} | @tools_decls]
    end
  end

  @doc """
  Returns all declared tools as a list of tool definition maps.
  """
  def list_tools_from_decls(decls) do
    Enum.map(decls, fn {name, opts} ->
      params = build_params_schema(opts[:params] || %{}, opts[:required] || [])

      %{
        "name" => to_string(name),
        "description" => opts[:description] || "",
        "inputSchema" => %{
          "type" => "object",
          "properties" => params[:properties],
          "required" => params[:required]
        }
      }
    end)
  end

  @doc """
  Builds the inputSchema params map from a list or map of params.
  """
  def build_params_schema(params, required) when is_list(params) do
    properties = Enum.into(params, %{}, fn p -> {p, %{"type" => "string"}} end)
    %{properties: properties, required: required}
  end

  def build_params_schema(params, required) when is_map(params) do
    required
  end

  @doc """
  Calls a tool handler given the tool name, args, and declarations.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def call_tool(name, args, decls) do
    case List.keyfind(decls, name, 0) do
      {^name, opts} ->
        handler = opts[:handler]
        apply_handler(handler, args)

      nil ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  defp apply_handler({mod, func}, args) when is_atom(func) do
    apply(mod, func, [args])
  end

  defp apply_handler(func, args) when is_atom(func) do
    func.(args)
  end
end
