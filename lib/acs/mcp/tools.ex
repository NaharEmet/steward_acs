defmodule Acs.MCP.Tools do
  @moduledoc """
  Central dispatch for all ACS MCP tool calls.

  Tools are dispatched via `call_tool/2` which routes to the appropriate
  handler module based on the `@simple_dispatch` map (static) and
  `dispatch_map/0` (dynamic closures).

  Logging, error handling, and basic param extraction happen here.
  """

  require Logger

  alias Acs.MCP.Tools.CoreHandlers
  alias Acs.MCP.Tools.ClusterHandlers
  alias Acs.MCP.Tools.CRMTools
  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.MCP.Tools.DiagnosticHandlers
  alias Acs.MCP.Tools.DynamicTools

  @simple_dispatch %{
    "create_work" => &CoreHandlers.create_work/1,
    "claim_work" => &CoreHandlers.claim_work/1,
    "release_work" => &CoreHandlers.release_work/1,
    "lock_file" => &CoreHandlers.lock_file/1,
    "unlock_file" => &CoreHandlers.unlock_file/1,
    "get_present_status" => &CoreHandlers.get_present_status/1,
    "get_locked_files" => &CoreHandlers.get_locked_files/1,
    "list_tasks" => &CoreHandlers.list_tasks/1,
    "sleep" => &CoreHandlers.sleep/1,
    "wake" => &CoreHandlers.wake/1,
    "create_task_from_error_trace" => &CoreHandlers.create_task_from_error_trace/1,
    "get_agent_tasks" => &CoreHandlers.get_agent_tasks/1,
    "save_memory" => &CoreHandlers.save_memory/1,
    "list_memories" => &CoreHandlers.list_memories/1,
    "search_memories" => &CoreHandlers.search_memories/1,
    "set_memory_status" => &CoreHandlers.set_memory_status/1,
    "list_error_traces" => &CoreHandlers.list_error_traces/1,
    "ack_error_trace" => &CoreHandlers.ack_error_trace/1,
    "resolve_error_trace" => &CoreHandlers.resolve_error_trace/1,
    "crm_list_sources" => &CRMTools.list_sources/1,
    "crm_get_sync_state" => &CRMTools.get_sync_state/1,
    "crm_sync" => &CRMTools.sync/1,
    "crm_sync_object_type" => &CRMTools.sync_object_type/1,
    "crm_trigger_scheduler" => &CRMTools.trigger_scheduler/1,
    "crm_get_scheduler_status" => &CRMTools.get_scheduler_status/1,
    "crm_get_field_config" => &CRMTools.get_field_config/1,
    "time" => &CoreHandlers.time/1,
    "submit_task_feedback" => &ErrorHandlers.acs_submit_task_feedback/1,
    "help" => &DiagnosticHandlers.acs_help/1,
    "query" => &DiagnosticHandlers.acs_query/1,
    "config_lookup" => &DiagnosticHandlers.config_lookup/1,
    "connection_diagnostic" => &DiagnosticHandlers.connection_diagnostic/1,
    "find_similar_code" => &DiagnosticHandlers.find_similar_code/1,
    "memory_health_check" => &DiagnosticHandlers.memory_health_check/1,
    "list_plugins" => &CoreHandlers.list_plugins/1,
    "read_file" => &ClusterHandlers.read_file/1,
    "write_file" => &ClusterHandlers.write_file/1,
    "read_dir" => &ClusterHandlers.read_dir/1
  }

  defp dispatch_map do
    # Tools needing closures (partial application) built at runtime
    %{
      "write_tool" => &DynamicTools.call_tool("write_tool", &1)
    }
  end

  def call_tool(name, args) do
    Logger.info("MCP tool: #{name} - #{tool_action_summary(name, args)}")

    if agent_id = Map.get(args, "agent_id") do
      case Acs.Acs.Cache.get_agent_status(agent_id) do
        {:ok, nil} ->
          Acs.Acs.Cache.put_agent_status(agent_id, %{purpose: "active", current_task_id: nil, application: nil, component: nil})

        _ ->
          :ok
      end
    end

    dispatch = Map.merge(@simple_dispatch, dispatch_map())

    case Map.fetch(dispatch, name) do
      {:ok, handler} ->
        try do
          case handler.(args) do
            {:ok, result} ->
              Logger.info("MCP tool response: #{name} - ok (keys: #{result_keys(result)})")
              {:ok, result}

            {:error, reason} ->
              Logger.warning("MCP tool response: #{name} - error: #{inspect(reason)}")
              {:error, reason}

            other ->
              Logger.warning("MCP tool response: #{name} - unexpected return: #{inspect(other)}")
              {:error, "Unexpected return from tool handler"}
          end
        rescue
          e ->
            Logger.error("MCP tool exception: #{name} - #{inspect(e)}")
            stacktrace = Exception.format_stacktrace(__STACKTRACE__)
            {:error, "Tool error: #{inspect(e)}\n#{stacktrace}"}
        catch
          kind, value ->
            Logger.error("MCP tool throw: #{name} - #{inspect(kind)}: #{inspect(value)}")
            {:error, "Tool error (throw): #{inspect(value)}"}
        end

      :error ->
        Logger.warning("MCP tool not found: #{name}")
        {:error, "Unknown tool: #{name}"}
    end
  end

  defp result_keys(map) when is_map(map), do: Map.keys(map) |> Enum.join(", ")
  defp result_keys(_), do: "non-map"

  # Tool action summaries for logging
  defp tool_action_summary("create_work", %{"title" => title}),
    do: "create work: #{title}"

  defp tool_action_summary("claim_work", %{"task_id" => task_id}),
    do: "claim task: #{task_id}"

  defp tool_action_summary("release_work", %{"task_id" => task_id}),
    do: "release task: #{task_id}"

  defp tool_action_summary("lock_file", %{"file_path" => path}),
    do: "lock: #{path}"

  defp tool_action_summary("unlock_file", %{"file_path" => path}),
    do: "unlock: #{path}"

  defp tool_action_summary("list_tasks", %{"agent_id" => id}),
    do: "list tasks for: #{id}"

  defp tool_action_summary("save_memory", %{"title" => title}),
    do: "save memory: #{title}"

  defp tool_action_summary("search_memories", %{"query" => q}),
    do: "search memories: #{q}"

  defp tool_action_summary("set_memory_status", %{"memory_id" => id, "status" => s}),
    do: "set memory #{id} → #{s}"

  defp tool_action_summary("list_error_traces", args),
    do: "list error traces: #{inspect(Map.take(args, ["status", "service", "component"]))}"

  defp tool_action_summary("ack_error_trace", %{"trace_id" => id}),
    do: "ack error trace: #{id}"

  defp tool_action_summary("resolve_error_trace", %{"trace_id" => id}),
    do: "resolve error trace: #{id}"

  defp tool_action_summary("create_task_from_error_trace", %{"trace_id" => id}),
    do: "create task from error trace: #{id}"

  defp tool_action_summary("submit_task_feedback", %{"task_id" => task_id}),
    do: "submit feedback for task=#{task_id}"

  # Cluster tools
  defp tool_action_summary("read_file", %{"path" => path}),
    do: "read: #{path}"

  defp tool_action_summary("write_file", %{"path" => path}),
    do: "write: #{path}"

  defp tool_action_summary("read_dir", %{"path" => path}),
    do: "ls: #{path}"

  defp tool_action_summary("read_file", _args), do: "read file"
  defp tool_action_summary("write_file", _args), do: "write file"
  defp tool_action_summary("read_dir", _args), do: "list dir"

  defp tool_action_summary(_name, _args), do: "called"

end
