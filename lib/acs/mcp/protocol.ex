defmodule Acs.MCP.Protocol do
  @moduledoc """
  Model Context Protocol (MCP) JSON-RPC message handling.

  Injects authentication context (`_auth_role`, `_auth_org_id`, `_auth_permissions`)
  into tool call arguments. `_auth_permissions` is always set (may be nil if the auth
  strategy doesn't provide permissions). Downstream RBAC enforcement in ToolRegistry
  checks these values against tool-level role and permission requirements.
  """

  alias Acs.MCP.ToolRegistry

  @mcp_version "2024-11-05"

  @doc """
  Processes a JSON-RPC message and returns the appropriate response.

  Accepts optional authentication context:
  - `agent_role` - Role assigned to the calling agent (required for `tools/list` and `tools/call`)
  - `agent_org_id` - Organization ID for the calling agent
  - `agent_permissions` - List of permission strings for the calling agent
    (used for permission-based RBAC, see `permissions` in YAML tool definitions)
  """
  @spec handle_message(String.t() | map(), binary() | nil, binary() | nil, list(String.t()) | nil) ::
          {:ok, map() | nil}
          | {:error, String.t()}
          | {:sleep, any(), String.t(), integer() | :infinity}

  def handle_message(
        message,
        agent_role \\ nil,
        agent_org_id \\ nil,
        agent_permissions \\ nil,
        agent_allowed_teams \\ nil,
        agent_allowed_projects \\ nil,
        agent_identity \\ nil
      )

  def handle_message(
        message,
        agent_role,
        agent_org_id,
        agent_permissions,
        agent_allowed_teams,
        agent_allowed_projects,
        agent_identity
      )
      when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} ->
        handle_message(
          decoded,
          agent_role,
          agent_org_id,
          agent_permissions,
          agent_allowed_teams,
          agent_allowed_projects,
          agent_identity
        )

      {:error, reason} ->
        {:error, "Failed to parse JSON: #{inspect(reason)}"}
    end
  end

  def handle_message(
        %{"jsonrpc" => "2.0", "id" => id, "method" => method} = msg,
        agent_role,
        agent_org_id,
        agent_permissions,
        agent_allowed_teams,
        agent_allowed_projects,
        agent_identity
      )
      when not is_nil(id) do
    params = msg["params"] || %{}

    handle_request(
      id,
      method,
      params,
      agent_role,
      agent_org_id,
      agent_permissions,
      agent_allowed_teams,
      agent_allowed_projects,
      agent_identity
    )
  end

  def handle_message(
        %{"jsonrpc" => "2.0", "method" => method} = msg,
        _agent_role,
        _agent_org_id,
        _agent_permissions,
        _agent_allowed_teams,
        _agent_allowed_projects,
        _agent_identity
      ) do
    params = msg["params"] || %{}
    handle_notification(method, params)
  end

  def handle_message(
        %{"jsonrpc" => "2.0"} = _msg,
        _agent_role,
        _agent_org_id,
        _agent_permissions,
        _agent_allowed_teams,
        _agent_allowed_projects,
        _agent_identity
      ) do
    {:ok, error_response(nil, -32600, "Invalid Request", "Missing method")}
  end

  def handle_message(
        _msg,
        _agent_role,
        _agent_org_id,
        _agent_permissions,
        _agent_allowed_teams,
        _agent_allowed_projects,
        _agent_identity
      ) do
    {:ok, error_response(nil, -32600, "Invalid Request", "Not a valid JSON-RPC 2.0 message")}
  end

  @doc """
  Builds a success JSON-RPC response.
  """
  def success_response(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  @doc """
  Builds an error JSON-RPC response.
  """
  def error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  defp handle_request(
         id,
         "initialize",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    result = %{
      "protocolVersion" => @mcp_version,
      "capabilities" => server_capabilities(),
      "serverInfo" => server_info()
    }

    {:ok, success_response(id, result)}
  end

  defp handle_request(
         id,
         "tools/list",
         _params,
         agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    with :ok <- require_agent_role(agent_role) do
      tools = ToolRegistry.list_tools_mcp(agent_role)
      {:ok, success_response(id, %{"tools" => tools})}
    else
      {:error, reason} ->
        {:ok, error_response(id, -32001, "Unauthorized", reason)}
    end
  end

  defp handle_request(
         id,
         "tools/call",
         params,
         agent_role,
         agent_org_id,
         agent_permissions,
         agent_allowed_teams,
         agent_allowed_projects,
         agent_identity
       ) do
    with :ok <- require_agent_role(agent_role) do
      do_tools_call(
        id,
        params,
        agent_role,
        agent_org_id,
        agent_permissions,
        agent_allowed_teams,
        agent_allowed_projects,
        agent_identity
      )
    else
      {:error, reason} ->
        {:ok, error_response(id, -32001, "Unauthorized", reason)}
    end
  end

  defp handle_request(
         id,
         "ping",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    {:ok, success_response(id, %{})}
  end

  # OpenCode startup methods — return empty/success responses to avoid "Method not found" errors
  defp handle_request(
         id,
         "config.providers",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    {:ok, success_response(id, %{"providers" => []})}
  end

  defp handle_request(
         id,
         "provider.list",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    {:ok, success_response(id, %{"providers" => []})}
  end

  defp handle_request(
         id,
         "app.agents",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    {:ok, success_response(id, %{"agents" => []})}
  end

  defp handle_request(
         id,
         "config.get",
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    {:ok, success_response(id, %{})}
  end

  defp handle_request(
         id,
         method,
         _params,
         _agent_role,
         _agent_org_id,
         _agent_permissions,
         _agent_allowed_teams,
         _agent_allowed_projects,
         _agent_identity
       ) do
    {:ok, error_response(id, -32601, "Method not found", method)}
  end

  defp handle_notification("initialized", _params), do: {:ok, nil}
  defp handle_notification("notifications/initialized", _params), do: {:ok, nil}
  defp handle_notification("shutdown", _params), do: {:ok, nil}
  defp handle_notification("$/cancelRequest", _params), do: {:ok, nil}
  defp handle_notification(_method, _params), do: {:ok, nil}

  defp require_agent_role(role) when is_binary(role) and role != "", do: :ok
  defp require_agent_role(_), do: {:error, "Missing authentication context"}

  defp do_tools_call(
         id,
         params,
         agent_role,
         agent_org_id,
         agent_permissions,
         agent_allowed_teams,
         agent_allowed_projects,
         agent_identity
       ) do
    name = params["name"]

    arguments =
      (params["arguments"] || %{})
      |> Map.put("_auth_role", agent_role)
      |> Map.put("_auth_org_id", agent_org_id)
      |> Map.put("_auth_permissions", agent_permissions)
      |> Map.put("_auth_allowed_teams", agent_allowed_teams)
      |> Map.put("_auth_allowed_projects", agent_allowed_projects)
      |> Map.put("_auth_agent_id", agent_identity)

    if is_nil(name) do
      {:ok, error_response(id, -32602, "Invalid params", "Missing 'name' parameter")}
    else
      case ToolRegistry.authorize_tool(name, agent_role, agent_permissions) do
        :ok ->
          call_result =
            if is_binary(agent_org_id) and agent_org_id != "" do
              Acs.Org.with_current(agent_org_id, fn ->
                ToolRegistry.call_tool(name, arguments)
              end)
            else
              {:error, "Missing organization authentication context"}
            end

          case call_result do
            {:ok, result} ->
              {:ok,
               success_response(id, %{
                 "content" => [%{"type" => "text", "text" => Jason.encode!(result, pretty: true)}]
               })}

            {:error, reason} ->
              {:ok,
               success_response(id, %{
                 "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
                 "isError" => true
               })}

            {:sleep, agent_id, timeout} ->
              {:sleep, id, agent_id, timeout}
          end

        {:error, reason} ->
          {:ok,
           success_response(id, %{
             "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
             "isError" => true
           })}
      end
    end
  end

  defp server_capabilities do
    %{
      "tools" => %{
        "listChanged" => true,
        "progressiveDisclosure" => true
      }
    }
  end

  defp server_info do
    %{"name" => "Acs MCP Server", "version" => "0.1.0"}
  end
end
