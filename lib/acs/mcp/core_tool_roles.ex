defmodule Acs.MCP.CoreToolRoles do
  @moduledoc """
  Role assignments for built-in tools dispatched via `Acs.MCP.Tools`.

  YAML-loaded tools use their own `roles` field. Core tools fall back to this
  map so `ToolRegistry.authorize_tool/3` enforces the same RBAC model.
  """

  @admin_only ~w(
    query
    config_lookup
    connection_diagnostic
    find_similar_code
    memory_health_check
    get_logs
    list_orgs
    app_configure
    app_remove
    write_file
    write_tool
    set_memory_status
    ack_error_trace
    resolve_error_trace
    create_task_from_error_trace
  )

  @admin_collaborator ~w(
    claim_work
    release_work
    create_work
    lock_file
    unlock_file
    get_present_status
    get_locked_files
    list_tasks
    sleep
    wake
    submit_task_feedback
    help
    save_memory
    list_memories
    search_memories
    generate_guidance_packet
    ask
    list_error_traces
    read_file
    read_dir
    list_plugins
    app_list
  )

  @admin_service ~w(time)

  @roles Map.new(@admin_only, &{&1, ["admin"]})
           |> Map.merge(Map.new(@admin_collaborator, &{&1, ["admin", "collaborator"]}))
           |> Map.merge(Map.new(@admin_service, &{&1, ["admin", "service", "collaborator"]}))

  @default_roles ["admin"]

  @doc "Returns the roles allowed to call a core tool."
  @spec roles_for(String.t()) :: [String.t()]
  def roles_for(name) when is_binary(name), do: Map.get(@roles, name, @default_roles)

  @doc "Returns true when `role` may invoke the core tool."
  @spec authorized?(String.t(), String.t()) :: boolean()
  def authorized?(name, role) when is_binary(name) and is_binary(role) do
    role in roles_for(name)
  end

  def authorized?(_, _), do: false
end
