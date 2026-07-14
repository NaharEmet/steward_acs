defmodule Acs.MCP.Tools.CoreHandlers do
  @moduledoc """
  Handles core ACS MCP tools for agent task and file lifecycle.

  ## Purpose

  Implements the handler functions for agent coordination tools:
  creating, claiming, and releasing tasks; locking and unlocking files;
  agent sleep/wake; present status queries; and log retrieval.

  ## Key Functions

  - `acs_claim_work/1` — Claims a task for an agent
  - `acs_release_work/1` — Releases a task and returns feedback prompt
  - `acs_create_work/1` — Creates a new task with dedup warnings
  - `acs_lock_file/1` — Locks a file for exclusive editing
  - `acs_unlock_file/1` — Unlocks a file or all files for a task
  - `acs_get_present_status/1` — Returns agent status or assigns agent ID
  - `acs_sleep/1` — Puts agent to sleep until task arrives
  - `acs_wake/1` — Wakes a sleeping agent
  - `get_logs/1` — Retrieves application logs with filters
  - `acs_time/1` — Gets or sets ACS time offset
  """
  alias Acs.Acs.Cache
  alias Acs.Acs.SleepRegistry
  alias Acs.MCP.LogStore
  require Logger
  import Ecto.Query, only: [from: 2]

  @doc false
  def sleep_and_wait(agent_id, timeout) do
    case SleepRegistry.register(agent_id, timeout) do
      {:ok, ref, _status} ->
        do_wait_for_task(ref, agent_id, timeout)

      {:ok, ref, :immediate, _task_id} ->
        do_wait_for_task(ref, agent_id, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_claim_work(%{"agent_id" => agent_id, "task_id" => task_id} = args) do
    scope_path = args["scope_path"]
    opts = if scope_path, do: [skip_guidance: true], else: []

    case Acs.claim_task(task_id, agent_id, opts) do
      {:ok, _task, guidance} ->
        application = args["application"]
        component = args["component"]

        if application || component do
          Acs.update_agent_context(agent_id, application, component)
        end

        final_guidance =
          if scope_path do
            Acs.Memory.Guidance.generate(scope_path, tier: :claim)
          else
            guidance
          end

        {:ok,
         %{
           status: "claimed",
           task_id: task_id,
           agent_id: agent_id,
           guidance: final_guidance
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_release_work(%{"agent_id" => agent_id, "task_id" => task_id}) do
    case Acs.release_task(task_id, agent_id) do
      {:ok, _task} ->
        {:ok,
         %{
           status: "done",
           task_id: task_id,
           agent_id: agent_id,
           message: "Task released. Now call submit_task_feedback to formally close it."
         }}

      {:error, :not_owner} ->
        {:ok, %{status: "not_owner", message: "Task locked by another agent"}}

      {:error, reason} when is_atom(reason) ->
        {:error, Atom.to_string(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_create_work(%{"agent_id" => agent_id, "title" => title} = args) do
    claim = args["claim"] || false

    attrs = %{
      "title" => title,
      "description" => args["description"] || "",
      "file_paths" => args["file_paths"] || []
    }

    case Acs.create_task(attrs, agent_id) do
      {:ok, task} ->
        if claim do
          case Acs.claim_task(task.id, agent_id) do
            {:ok, _task, guidance} ->
              {:ok, %{status: "claimed", task_id: task.id, title: task.title, guidance: guidance}}

            {:error, reason} ->
              {:ok,
               %{status: "created", task_id: task.id, title: task.title, claim_error: reason}}
          end
        else
          SleepRegistry.try_dispatch(task.id)
          {:ok, %{status: "ok", task_id: task.id, title: task.title}}
        end

      {:warn, task, similar} ->
        if claim do
          case Acs.claim_task(task.id, agent_id) do
            {:ok, _task, guidance} ->
              {:ok,
               %{
                 status: "claimed",
                 task_id: task.id,
                 title: task.title,
                 guidance: guidance,
                 similar_tasks: similar
               }}

            {:error, reason} ->
              {:ok,
               %{
                 status: "created",
                 task_id: task.id,
                 title: task.title,
                 similar_tasks: similar,
                 claim_error: reason
               }}
          end
        else
          SleepRegistry.try_dispatch(task.id)
          {:ok, %{status: "warning", task_id: task.id, title: task.title, similar_tasks: similar}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_lock_file(%{"agent_id" => agent_id, "task_id" => task_id, "file_path" => file_path}) do
    case Acs.lock_file(file_path, agent_id, task_id) do
      {:ok, result} ->
        # Add file locking protocol guidance to the response
        guidance = Map.get(result, :guidance, %{})

        file_locking_protocol = """
        ## File Locking Protocol

        - **AFTER editing**: `acs_unlock_file(agent_id, file_path: "#{file_path}")` when done
        - **10-minute auto-release** if agent goes silent
        - Call `acs_get_locked_files()` to see all locked files
        """

        final_guidance =
          if guidance == %{},
            do: %{},
            else: Map.put(guidance, :file_locking_protocol, file_locking_protocol)

        {:ok, Map.put(result, :guidance, final_guidance)}

      {:error, :file_locked_by_other} ->
        {:error,
         "File already locked by another agent. Wait and retry, or use `get_locked_files()` to check current locks."}

      {:error, :task_not_locked_by_agent} ->
        {:error,
         "Task not locked by this agent. Claim the task first with `claim_work(\"<agent_id>\", task_id: \"#{task_id}\")` before locking files."}

      {:error, :task_not_found} ->
        {:error,
         "Task not found. The task may have been released or never existed. Create and claim a new task: `create_work(\"<agent_id>\", \"<title>\", claim: true)`"}

      {:error, :already_locked} ->
        {:ok, %{status: "already_locked", message: "File already locked"}}

      {:error, reason} when is_atom(reason) ->
        {:error, Atom.to_string(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_lock_file(%{"agent_id" => agent_id, "task_id" => task_id, "filePath" => file_path}) do
    acs_lock_file(%{"agent_id" => agent_id, "task_id" => task_id, "file_path" => file_path})
  end

  def acs_unlock_file(%{"agent_id" => agent_id, "task_id" => task_id}) when is_binary(task_id) do
    Acs.unlock_files_for_task(task_id, agent_id)
    {:ok, %{status: "ok", message: "All files unlocked for task: #{task_id}"}}
  end

  def acs_unlock_file(%{"agent_id" => agent_id, "file_path" => file_path}) do
    case Acs.unlock_file(file_path, agent_id) do
      :ok -> {:ok, %{status: "ok", message: "File unlocked: #{file_path}"}}
      {:error, reason} -> {:error, reason}
    end
  end

  def acs_unlock_file(%{"agent_id" => agent_id, "filePath" => file_path}) do
    acs_unlock_file(%{"agent_id" => agent_id, "file_path" => file_path})
  end

  def acs_unlock_file(%{"agent_id" => _agent_id}) do
    {:error, "Either file_path or task_id is required"}
  end

  def acs_get_started(_args) do
    {:ok,
     %{
       general:
         "ACS coordinates agent work. Create tasks, claim them, lock files, edit, save learnings as memories, release. Every response includes `_next` with suggested next tools.",
       get_started:
         "1) `get_present_status(agent_id: \"your_name\")` — register  2) `create_work(agent_id, title, claim: true)` — create + claim  3) `skill_get(search: title)` — find workflow guides  4) `query_specs(query: title)` — check module docs  5) `lock_file` files  6) do work  7) `save_memory` learnings  8) `unlock_file`  9) `release_work`  10) `submit_task_feedback`",
       tools: [
         %{
           tool: "get_present_status",
           description: "Register and see all active agents",
           params: %{agent_id: "your_name"}
         },
         %{
           tool: "create_work",
           description: "Create and self-claim a task (default flow)",
           params: %{agent_id: "your_name", title: "...", claim: true}
         },
         %{
           tool: "list_tasks",
           description: "Find existing tasks to claim",
           params: %{status_filter: "todo"}
         },
         %{
           tool: "claim_work",
           description: "Claim an existing task",
           params: %{agent_id: "your_name", task_id: "<id>"}
         },
         %{
           tool: "generate_guidance_packet",
           description: "Get detailed guidance for a scope path",
           params: %{scope_path: "agent_coordination_system"}
         },
         %{
           tool: "help",
           description: "List all tools with full descriptions",
           params: %{level: 1}
         },
         %{
           tool: "skill_get",
           description: "Find or list reusable workflow guides",
           params: %{search: "...", tag: "..."}
         },
         %{
           tool: "skill_save",
           description: "Create a reusable workflow guide for other agents",
           params: %{name: "...", content: "...", tags: ["..."]}
         },
         %{
           tool: "skill_audit_status",
           description: "Audit all skills for quality and completeness",
           params: %{}
         }
       ]
     }}
  end

  def acs_get_present_status(%{"status_filter" => "sleeping"}) do
    agents = SleepRegistry.list_sleeping_agents()
    {:ok, %{sleeping_agents: agents, count: length(agents)}}
  end

  def acs_get_present_status(%{"agent_id" => agent_id})
      when agent_id != nil and agent_id != "" do
    statuses = Acs.Acs.get_present_status()
    my_status = Enum.find(statuses, %{}, fn s -> s.agent_id == agent_id end)
    {:ok, %{agents: statuses, agent: my_status, agent_id: agent_id}}
  end

  def acs_get_present_status(%{"status_filter" => _filter}) do
    {:ok, Acs.Acs.get_present_status()}
  end

  def acs_get_present_status(args) do
    agent_name =
      case Map.get(args, "_auth_agent_id") do
        nil -> Cache.get_and_increment_agent_index()
        "" -> Cache.get_and_increment_agent_index()
        auth_id -> auth_id
      end

    case Acs.Acs.get_agent_status(agent_name) do
      nil -> Acs.Acs.put_agent_status(agent_name, %{current_task_id: nil, purpose: "active"})
      _ -> :ok
    end

    {:ok, %{agents: Acs.Acs.get_present_status(), assigned_agent_id: agent_name}}
  end

  def acs_get_locked_files(_) do
    locks = Acs.Acs.get_locked_files()

    {:ok,
     Enum.map(locks, fn l ->
       %{
         id: l.id,
         file_path: l.file_path,
         locked_by_agent: l.locked_by_agent,
         locked_at: l.locked_at,
         auto_release_at: l.auto_release_at,
         task_id: l.task_id
       }
     end)}
  end

  def acs_list_tasks(args) when is_map(args) do
    status_filter = Map.get(args, "status_filter")
    status_filter = if status_filter == "all", do: nil, else: status_filter
    org = authenticated_org(args)
    tasks = Acs.Acs.list_tasks(status_filter, org)

    formatted =
      Enum.map(tasks, fn t ->
        %{
          id: t.id,
          title: t.title,
          description: t.description,
          status: t.status,
          locked_by_agent: t.locked_by_agent
        }
      end)

    {:ok, %{tasks: formatted, count: length(formatted)}}
  end

  defp authenticated_org(args) do
    case Map.get(args, "_auth_org_id") do
      org when is_binary(org) and org != "" -> org
      _ -> Acs.Org.current()
    end
  end

  defp do_wait_for_task(ref, agent_id, timeout) do
    mon_ref = Process.monitor(Acs.Acs.SleepRegistry)

    result =
      receive do
        {:task_assigned, ^ref, task_id} ->
          Process.demonitor(mon_ref, [:flush])

          {:ok,
           %{
             status: "woken",
             task_id: task_id,
             message: "Task available. Call claim_work with the task_id to claim it."
           }}

        {:cancelled, ^ref} ->
          Process.demonitor(mon_ref, [:flush])
          {:ok, %{status: "cancelled", message: "Sleep was cancelled by administrator"}}

        {:DOWN, ^mon_ref, :process, _pid, reason} ->
          {:error, "Sleep registry crashed: #{inspect(reason)}"}
      after
        timeout ->
          Process.demonitor(mon_ref, [:flush])
          SleepRegistry.unregister(agent_id)
          {:ok, %{status: "timeout", message: "No task arrived within the timeout period"}}
      end

    result
  end

  def acs_sleep(args) do
    agent_id = args["agent_id"]
    timeout = parse_timeout(args["timeout"])

    cond do
      is_nil(agent_id) ->
        {:error, "Missing agent_id"}

      has_active_task?(agent_id) ->
        {:error, "Agent #{agent_id} has an active task. Release or complete it before sleeping."}

      true ->
        # Register agent in AgentStatus so it appears in present_status
        Acs.Acs.put_agent_status(agent_id, %{current_task_id: nil, purpose: "sleeping"})
        {:sleep, agent_id, timeout}
    end
  end

  defp has_active_task?(agent_id) do
    org = Acs.Org.current()

    count =
      Acs.Repo.one(
        from t in Acs.Acs.Task,
          where: t.locked_by_agent == ^agent_id,
          where: t.status == "in_progress",
          where: t.org == ^org,
          select: count()
      )

    count > 0
  end

  defp parse_timeout(nil), do: :infinity
  defp parse_timeout(0), do: :infinity
  defp parse_timeout(t) when is_integer(t) and t > 0, do: t
  defp parse_timeout(_), do: :infinity

  def acs_wake(args) do
    agent_id = args["agent_id"]

    if is_nil(agent_id) do
      {:error, "Missing agent_id"}
    else
      case SleepRegistry.wake_agent(agent_id) do
        {:ok, :cancelled} -> {:ok, %{status: "woken", agent_id: agent_id}}
        {:error, :not_sleeping} -> {:error, "Agent #{agent_id} is not sleeping"}
      end
    end
  end

  def get_logs(args) do
    mode = Map.get(args, "mode", "list")

    opts = [
      level: Map.get(args, "level"),
      component: Map.get(args, "component"),
      module: Map.get(args, "module"),
      search: Map.get(args, "search"),
      action: Map.get(args, "action"),
      tags: Map.get(args, "tags"),
      service: Map.get(args, "service"),
      workflow_id: Map.get(args, "workflow_id"),
      execution_id: Map.get(args, "execution_id"),
      since: Map.get(args, "since"),
      until: Map.get(args, "until"),
      limit: Map.get(args, "limit") || 100,
      offset: Map.get(args, "offset") || 0,
      compact: Map.get(args, "compact") || false,
      before_id: Map.get(args, "before_id"),
      after_id: Map.get(args, "after_id"),
      context_size: Map.get(args, "context_size") || 5
    ]

    result = LogStore.get_logs(opts, mode)

    case mode do
      "summary" ->
        {:ok, result}

      "errors_with_context" ->
        {:ok,
         %{
           logs: result.logs,
           count: result.count,
           filtered_total: result.filtered_total,
           note: "Context entries are from the full log timeline (filters not applied to context)"
         }}

      _ ->
        {:ok,
         %{
           logs: result.logs,
           count: result.count,
           filtered_total: result.filtered_total,
           total: result.total
         }}
    end
  end

  def list_orgs(args) do
    app_name = Map.get(args, "app_name")
    orgs = Acs.Acs.list_orgs(app_name)

    records =
      Enum.map(orgs, fn o ->
        %{id: o["id"], name: o["name"], settings: o["settings"], inserted_at: o["inserted_at"]}
      end)

    {:ok, %{orgs: records, count: length(records)}}
  end

  def app_list(_args) do
    apps = Acs.Apps.Config.list_apps()

    entries =
      Enum.map(apps, fn {name, config} ->
        %{
          name: name,
          base_url: Keyword.get(config, :base_url),
          has_api_key: not is_nil(Keyword.get(config, :api_key)),
          auth_endpoint: Keyword.get(config, :auth_endpoint),
          auth_header_name: Keyword.get(config, :auth_header_name) || "authorization",
          auth_header_scheme: Keyword.get(config, :auth_header_scheme) || "Bearer",
          timeout_ms: Keyword.get(config, :timeout_ms) || 30_000
        }
      end)

    {:ok, %{apps: entries, count: length(entries)}}
  end

  def app_configure(args) do
    name = Map.get(args, "name")
    base_url = Map.get(args, "base_url")
    api_key = Map.get(args, "api_key")
    auth_endpoint = Map.get(args, "auth_endpoint")
    auth_header_name = Map.get(args, "auth_header_name")
    auth_header_scheme = Map.get(args, "auth_header_scheme")
    timeout_ms = Map.get(args, "timeout_ms")

    config =
      []
      |> then(fn c -> if base_url, do: Keyword.put(c, :base_url, base_url), else: c end)
      |> then(fn c -> if api_key, do: Keyword.put(c, :api_key, api_key), else: c end)
      |> then(fn c ->
        if auth_endpoint, do: Keyword.put(c, :auth_endpoint, auth_endpoint), else: c
      end)
      |> then(fn c ->
        if auth_header_name, do: Keyword.put(c, :auth_header_name, auth_header_name), else: c
      end)
      |> then(fn c ->
        if auth_header_scheme,
          do: Keyword.put(c, :auth_header_scheme, auth_header_scheme),
          else: c
      end)
      |> then(fn c -> if timeout_ms, do: Keyword.put(c, :timeout_ms, timeout_ms), else: c end)

    Acs.Apps.Config.configure_app(name, config)
    {:ok, %{status: "ok", app: name}}
  end

  def app_remove(args) do
    name = Map.get(args, "name")
    Acs.Apps.Config.remove_app(name)
    {:ok, %{status: "ok", app: name}}
  end

  def acs_time(%{"action" => "get"} = args) do
    with :ok <- authorize_time_read(args) do
      offset = Acs.Acs.get_time_offset()
      system_time = DateTime.utc_now()
      adjusted_time = Acs.Acs.adjusted_now()

      {:ok,
       %{
         time_offset: offset,
         system_time: system_time,
         adjusted_time: adjusted_time
       }}
    end
  end

  def acs_time(%{"action" => "set", "seconds" => seconds} = args) when is_integer(seconds) do
    with :ok <- authorize_time_write(args) do
      Acs.Acs.set_time_offset(seconds)
      {:ok, %{status: "ok", message: "Time offset set to #{seconds} seconds"}}
    end
  end

  def acs_time(%{"action" => "set"} = args) do
    seconds = args["seconds"]

    if is_nil(seconds) do
      {:error, "Missing required parameter: seconds"}
    else
      {:error, "seconds must be an integer"}
    end
  end

  def acs_time(%{"action" => action}) do
    {:error, "Unknown action '#{action}'. Use 'get' or 'set'."}
  end

  defp authorize_time_read(args) do
    role = Map.get(args, "_auth_role", "admin")

    if role in ["admin", "service", "collaborator"] do
      :ok
    else
      {:error, "Role '#{role}' is not authorized to read ACS time"}
    end
  end

  defp authorize_time_write(args) do
    role = Map.get(args, "_auth_role", "admin")

    if role in ["admin", "service"] do
      :ok
    else
      {:error, "Only admin or service roles may set ACS time offset"}
    end
  end

  def list_plugins(_args) do
    Acs.MCP.ToolRegistry.list_plugins()
  end
end
