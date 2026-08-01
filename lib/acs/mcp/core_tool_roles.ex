defmodule Acs.MCP.CoreToolRoles do
  @moduledoc """
  Role assignments for built-in tools dispatched via `Acs.MCP.Tools`.

  YAML-loaded tools use their own `roles` field. Core tools fall back to this
  map so `ToolRegistry.authorize_tool/3` enforces the same RBAC model.

  ## Chat surface

  Chat assistants (Claude.ai / ChatGPT connectors) get a **curated** tool list
  via `chat_surface/0` when session audience is `:chat`. Keep that list in sync
  with `priv/prompts/chat_system_prompt.md` and chat guidance packets.

  Session-critical tools get `_meta["anthropic/alwaysLoad"]` via a short
  ordered `eager_priority/0` list (`ask` and `get_started` first). Claude may
  truncate large alwaysLoad budgets — keep that list small.
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
    ack_error_trace
    resolve_error_trace
    create_task_from_error_trace
    generate_developer_key
    list_developer_keys
    revoke_developer_key
    create_org
    upsert_authority_level
    delete_authority_level
    set_member_authority_level
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
    resolve_user_task
    sleep
    wake
    submit_task_feedback
    help
    save_memory
    query_memories
    set_memory_status
    get_person_status
    set_person_status
    list_authority_levels
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
  # set_memory_status on chat is limited to stale/deprecated in MemoryHandlers.
  @chat_surface ~w(
    get_started
    ask
    save_memory
    set_memory_status
    get_person_status
    set_person_status
    documents_propose
    skill_get
    skill_save
    create_work
    claim_work
    release_work
    list_tasks
    resolve_user_task
    get_present_status
    submit_task_feedback
  )

  # Ordered alwaysLoad list. Claude truncates large alwaysLoad budgets — put
  # ask + get_started first so they survive. Keep this ~10 tools max.
  # Remaining chat_surface tools stay discoverable via searchHint.
  @eager_priority ~w(
    ask
    get_started
    get_present_status
    save_memory
    skill_get
    create_work
    claim_work
    release_work
    submit_task_feedback
    lock_file
    unlock_file
    help
  )

  @search_hints %{
    "ask" => "steward ask retrieve search memories documents knowledge status",
    "get_started" => "steward get started startup instructions guidance onboard",
    "get_present_status" => "steward register agent identity status",
    "save_memory" => "steward save memory truth decision invariant",
    "skill_get" => "steward skill procedure how-to",
    "skill_save" => "steward skill save procedure",
    "documents_propose" => "steward document policy brief propose",
    "list_tasks" => "steward list tasks todo reminders user",
    "create_work" => "steward create claim task reminder due",
    "resolve_user_task" => "steward resolve reminder done dismiss snooze",
    "claim_work" => "steward claim task",
    "release_work" => "steward release task",
    "submit_task_feedback" => "steward feedback close task"
  }

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

  @doc """
  Tools that must stay in the model context under Anthropic Tool Search.

  Ordered via `eager_priority/0` — `ask` and `get_started` come first so they
  survive Claude's alwaysLoad budget. Emits `_meta["anthropic/alwaysLoad"]`.
  """
  @spec eager_tool?(String.t()) :: boolean()
  def eager_tool?(name) when is_binary(name), do: name in @eager_priority
  def eager_tool?(_), do: false

  @doc "Priority order for alwaysLoad tools (`ask` / `get_started` first)."
  @spec eager_priority() :: [String.t()]
  def eager_priority, do: @eager_priority

  @doc "Sort key so eager tools lead tools/list (ask/get_started first)."
  @spec list_sort_key(map()) :: {integer(), integer() | String.t()}
  def list_sort_key(%{"name" => name}) do
    case Enum.find_index(@eager_priority, &(&1 == name)) do
      nil -> {1, name}
      idx -> {0, idx}
    end
  end

  def list_sort_key(_), do: {1, ""}

  @doc "Attach Anthropic alwaysLoad / searchHint `_meta`."
  @spec with_eager_meta(map()) :: map()
  def with_eager_meta(%{"name" => name} = tool) do
    meta =
      %{}
      |> maybe_put_meta("anthropic/alwaysLoad", eager_tool?(name) && true)
      |> maybe_put_meta("anthropic/searchHint", Map.get(@search_hints, name))

    if meta == %{}, do: tool, else: Map.put(tool, "_meta", meta)
  end

  def with_eager_meta(tool), do: tool

  defp maybe_put_meta(meta, _key, false), do: meta
  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, key, value), do: Map.put(meta, key, value)

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
