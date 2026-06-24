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
    case Acs.claim_task(task_id, agent_id) do
      {:ok, _task, guidance} ->
        application = args["application"]
        component = args["component"]

        if application || component do
          Acs.update_agent_context(agent_id, application, component)
        end

        final_guidance =
          if scope_path = args["scope_path"] do
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
           feedback_prompt: %{
             message:
               "Task completed! Please share what you learned AND propose any cognition specs. Also rate how helpful the guidance packet was for this task.",
             next_step: %{
               tool: "submit_task_feedback",
               prompt: "Call this tool with the task_id and any learnings you want to share:",
                params: %{
                  task_id: task_id,
                  agent_id: agent_id,
                  learned_for_agents:
                   "(optional) What did you learn that will help future agents?",
                 had_issues: "(optional) What issues or obstacles did you encounter?",
                 improvements: "(optional) What could have made this task easier?",
                 guidance_useful: "Was the guidance packet helpful? (true/false)",
                 guidance_items_helpful:
                   "(optional) List memory IDs from guidance that were helpful",
                 guidance_items_confusing:
                   "(optional) List memory IDs from guidance that were confusing",
                 guidance_missing: "(optional) What guidance was needed but not provided?"
               }
             },
             cognition_reminder: %{
               prompt:
                 "For each module you worked on, check if it has a cognition spec. If not, call cognition_propose to document it. Use cognition_list_undocumented() to find modules missing specs.",
               actions: [
                 %{
                   tool: "cognition_list_undocumented",
                   description: "Find modules without specs"
                 },
                 %{
                   tool: "cognition_propose",
                   description: "Document any undocumented modules",
                   params: %{
                     app: "anantha",
                     path: "module_path",
                     title: "Module name",
                     purpose: "Why this module exists",
                     invariants: ["truth1", "truth2"],
                     workflows: ["expected execution"],
                     failure_modes: ["known failure scenario"],
                     constraints: ["non-goals"],
                     tags: ["category"]
                   }
                 }
               ]
             }
           }
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

    attrs = if claim, do: Map.put(attrs, "status", "claimed"), else: attrs

    case Acs.create_task(attrs, agent_id) do
      {:ok, task} ->
        unless claim, do: SleepRegistry.try_dispatch(task.id)
        {:ok, %{status: "ok", task_id: task.id, title: task.title}}

      {:warn, task, similar} ->
        unless claim, do: SleepRegistry.try_dispatch(task.id)
        {:ok, %{status: "warning", task_id: task.id, title: task.title, similar_tasks: similar}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_lock_file(%{"agent_id" => agent_id, "task_id" => task_id, "file_path" => file_path}) do
    case Acs.lock_file(file_path, agent_id, task_id) do
      {:ok, _} = ok ->
        ok

      {:error, :file_locked_by_other} ->
        {:ok, %{status: "busy", message: "File already locked by another agent"}}

      {:error, :task_not_locked_by_agent} ->
        {:ok, %{status: "busy", message: "Task not locked by this agent"}}

      {:error, :task_not_found} ->
        {:error, "Task not found"}

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

  def acs_get_present_status(%{"status_filter" => "sleeping"}) do
    agents = SleepRegistry.list_sleeping_agents()
    {:ok, %{sleeping_agents: agents, count: length(agents)}}
  end

  def acs_get_present_status(%{"agent_id" => agent_id})
      when agent_id != nil and agent_id != "" do
    {:ok, Acs.Acs.get_present_status()}
  end

  def acs_get_present_status(%{"status_filter" => _filter}) do
    {:ok, Acs.Acs.get_present_status()}
  end

  def acs_get_present_status(_args) do
    agent_name = Cache.get_and_increment_agent_index()

    # Auto-register agent if not already in AgentStatus
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
    cluster = Map.get(args, "cluster", Acs.Cluster.current())
    tasks = Acs.Acs.list_tasks(status_filter, cluster)

    {:ok,
     Enum.map(tasks, fn t ->
       %{
         id: t.id,
         title: t.title,
         description: t.description,
         status: t.status,
         locked_by_agent: t.locked_by_agent
       }
     end)}
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
    cluster = Acs.Cluster.current()

    count =
      Acs.Repo.one(
        from t in Acs.Acs.Task,
          where: t.locked_by_agent == ^agent_id,
          where: t.status == "in_progress",
          where: t.cluster == ^cluster,
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

  def list_orgs(_args) do
    orgs = Acs.Acs.list_orgs()
    records = Enum.map(orgs, fn o -> %{id: o["id"], name: o["name"], settings: o["settings"], inserted_at: o["inserted_at"]} end)
    {:ok, %{orgs: records, count: length(records)}}
  end

  def acs_time(%{"action" => "get"}) do
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

  def acs_time(%{"action" => "set", "seconds" => seconds}) when is_integer(seconds) do
    Acs.Acs.set_time_offset(seconds)
    {:ok, %{status: "ok", message: "Time offset set to #{seconds} seconds"}}
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
end
