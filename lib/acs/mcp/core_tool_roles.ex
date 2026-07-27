defmodule Acs.MCP.CoreToolRoles do
  @moduledoc """
  Role assignments for built-in tools dispatched via `Acs.MCP.Tools`.

  YAML-loaded tools use their own `roles` field. Core tools fall back to this
  map so `ToolRegistry.authorize_tool/3` enforces the same RBAC model.

  ## Chat surface

  Chat assistants (Claude.ai / ChatGPT connectors) get a **curated** tool list
  via `chat_surface/0` when session audience is `:chat`. Keep that list in sync
  with `priv/prompts/chat_system_prompt.md` and chat guidance packets.
  """

  @admin_only ~w(
    query
    config_lookup
    connection_diagnostic
    memory_health_check
    get_logs
    list_orgs
    app_configure
    app_remove
    write_tool
    set_memory_status
    ack_error_trace
    resolve_error_trace
    create_task_from_error_trace
    generate_developer_key
    list_developer_keys
    revoke_developer_key
    create_org
    specs_approve
    specs_reject
    skill_audit_status
  )

  @admin_collaborator ~w(
    get_started
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
    query_memories
    generate_guidance_packet
    ask
    specs_get
    query_specs
    specs_propose
    documents_propose
    skill_get
    skill_save
    list_error_traces
    list_plugins
    app_list
  )

  # Curated tools for chat connectors — must match chat system prompt / guidance.
  # Chat says "documents", not "specs" — use documents_propose (alias of specs_propose).
  @chat_surface ~w(
    get_started
    ask
    save_memory
    documents_propose
    skill_get
    skill_save
    create_work
    claim_work
    release_work
    list_tasks
    get_present_status
    submit_task_feedback
  )

  @admin_service ~w(time)

  @roles Map.new(@admin_only, &{&1, ["admin"]})
         |> Map.merge(Map.new(@admin_collaborator, &{&1, ["admin", "collaborator"]}))
         |> Map.merge(Map.new(@admin_service, &{&1, ["admin", "service", "collaborator"]}))

  @default_roles ["admin"]

  @doc "Tools exposed to chat-audience MCP sessions (Claude.ai / ChatGPT)."
  @spec chat_surface() :: [String.t()]
  def chat_surface, do: @chat_surface

  @doc "Returns true when `name` is on the chat connector surface."
  @spec chat_tool?(String.t()) :: boolean()
  def chat_tool?(name) when is_binary(name), do: name in @chat_surface
  def chat_tool?(_), do: false

  @doc "Returns the roles allowed to call a core tool."
  @spec roles_for(String.t()) :: [String.t()]
  def roles_for(name) when is_binary(name), do: Map.get(@roles, name, @default_roles)

  @doc "Returns true when `role` may invoke the core tool (ignores audience)."
  @spec authorized?(String.t(), String.t()) :: boolean()
  def authorized?(name, role) when is_binary(name) and is_binary(role) do
    role in roles_for(name)
  end

  def authorized?(_, _), do: false

  @doc """
  Authorize with optional audience.

  When `audience` is `:chat`, the tool must also be on `chat_surface/0`.
  """
  @spec authorized?(String.t(), String.t(), atom() | String.t() | nil) :: boolean()
  def authorized?(name, role, audience) when is_binary(name) and is_binary(role) do
    authorized?(name, role) and audience_allows?(name, audience)
  end

  def authorized?(_, _, _), do: false

  defp audience_allows?(_name, audience) when audience in [nil, :coding, "coding", :mcp, "mcp"],
    do: true

  defp audience_allows?(name, audience) when audience in [:chat, "chat", :knowledge, "knowledge"],
    do: chat_tool?(name)

  defp audience_allows?(_name, _audience), do: true
end
