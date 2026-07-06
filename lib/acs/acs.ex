defmodule Acs.Acs do
  @moduledoc """
  Agent Coordination System - Core operations module.

  This module provides the main API for task management, file locking,
  and agent coordination. It delegates to Cache for in-memory state
  and Repo for persistent storage.
  """

  alias Acs.Repo
  alias Acs.Acs.Task
  alias Acs.Acs.FileLock
  alias Acs.Acs.AgentStatus
  alias Acs.Acs.Cache
  alias Acs.Acs.Time

  require Logger

  @doc """
  Claims a task for an agent. Delegates to Acs.claim_task.
  """
  def claim_task(task_id, agent_id, opts \\ []) do
    case Acs.claim_task(task_id, agent_id, opts) do
      {:ok, task, guidance} ->
        {:ok, task, guidance}

      {:error, reason} ->
        Logger.error("[Acs.Acs] claim_task failed: #{inspect(reason)}",
          agent_id: agent_id,
          task_id: task_id
        )

        {:error, %{reason: reason, agent_id: agent_id, task_id: task_id}}
    end
  end

  @doc """
  Gets a task by ID. Returns the task struct or nil.
  """
  def get_task(task_id) when is_binary(task_id) do
    Repo.get(Task, task_id)
  end

  @doc """
  Claims a task and returns guidance alongside the claimed task.

  Wraps `claim_task/2` and generates a guidance packet using
  the task's context. Returns `{:ok, task, guidance_packet}` on success.
  """
  def claim_task_with_guidance(task_id, agent_id)
      when is_binary(task_id) and is_binary(agent_id) do
    case claim_task(task_id, agent_id) do
      {:ok, task, guidance} ->
        {:ok, task, guidance}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Releases a task lock. Delegates to Acs.release_task.
  """
  def release_task(task_id, agent_id) do
    case Acs.release_task(task_id, agent_id) do
      {:ok, task} ->
        {:ok, task}

      {:error, reason} ->
        Logger.error("[Acs.Acs] release_task failed: #{inspect(reason)}",
          agent_id: agent_id,
          task_id: task_id
        )

        {:error, %{reason: reason, agent_id: agent_id, task_id: task_id}}
    end
  end

  @doc """
  Creates a new task. Delegates to Acs.create_task.
  """
  def create_task(attrs, agent_id) do
    case Acs.create_task(attrs, agent_id) do
      {:ok, task} ->
        {:ok, task}

      {:warn, task, similar} ->
        {:warn, task, similar}

      {:error, reason} ->
        Logger.error("[Acs.Acs] create_task failed: #{inspect(reason)}",
          agent_id: agent_id
        )

        {:error, reason}
    end
  end

  @doc """
  Lists tasks with optional status filter and org scope.
  """
  def list_tasks(status_filter \\ nil, org \\ nil) do
    org = org || Acs.Org.current()
    import Ecto.Query

    query =
      from(t in Task,
        where: t.org == ^org,
        order_by: [desc: t.inserted_at]
      )

    query =
      if status_filter do
        from(t in query, where: t.status == ^status_filter)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Locks a file for a task. Delegates to Acs.lock_file.
  """
  def lock_file(file_path, agent_id, task_id) do
    case Acs.lock_file(file_path, agent_id, task_id) do
      {:ok, _lock} ->
        {:ok, %{status: "locked", file_path: file_path}}

      {:error, reason} ->
        Logger.error("[Acs.Acs] lock_file failed: #{inspect(reason)}",
          agent_id: agent_id,
          task_id: task_id,
          file_path: file_path
        )

        {:error, %{reason: reason, agent_id: agent_id, task_id: task_id}}
    end
  end

  @doc """
  Unlocks a file. Returns :ok or {:error, reason}.
  """
  def unlock_file(file_path, agent_id) do
    case Cache.get_file_lock(file_path) do
      {:ok, nil} ->
        # Not locked, consider it success
        :ok

      {:ok, lock} when lock.locked_by_agent == agent_id ->
        # Delete from DB
        case Repo.get_by(FileLock, file_path: file_path) do
          nil ->
            Cache.delete_file_lock(file_path)
            :ok

          lock_record ->
            Repo.delete(lock_record)
            Cache.delete_file_lock(file_path)
            :ok
        end

      {:ok, lock} ->
        Logger.error("[Acs.Acs] unlock_file failed: not owner",
          agent_id: agent_id,
          file_path: file_path,
          locked_by: lock.locked_by_agent
        )

        {:error, "File locked by #{lock.locked_by_agent}, not #{agent_id}"}
    end
  end

  @doc """
  Unlocks all files for a task. Returns :ok or {:error, reason}.
  """
  def unlock_files_for_task(task_id, agent_id) do
    locks = Cache.get_file_locks_for_task(task_id)

    Enum.each(locks, fn lock ->
      if lock.locked_by_agent == agent_id do
        unlock_file(lock.file_path, agent_id)
      end
    end)

    :ok
  end

  @doc """
  Gets all currently locked files.
  """
  def get_locked_files do
    Cache.get_all_file_locks()
  end

  @doc """
  Gets current status of all agents.
  """
  def get_present_status do
    statuses = Cache.get_all_agent_statuses()

    Enum.map(statuses, fn s ->
      %{
        agent_id: Map.get(s, :agent_id),
        current_task_id: Map.get(s, :current_task_id),
        purpose: Map.get(s, :purpose),
        application: Map.get(s, :application),
        component: Map.get(s, :component)
      }
    end)
  end

  @doc """
  Gets status for a specific agent.
  """
  def get_agent_status(agent_id) do
    case Cache.get_agent_status(agent_id) do
      {:ok, nil} -> nil
      {:ok, status} -> status
    end
  end

  @doc """
  Updates agent status.
  """
  def put_agent_status(agent_id, attrs) do
    new_status =
      Map.merge(
        %{
          agent_id: agent_id,
          current_task_id: nil,
          purpose: nil,
          application: nil,
          component: nil
        },
        attrs
      )

    # Get existing record or create new one for insert_or_update
    status_record =
      case Repo.get(AgentStatus, agent_id) do
        nil -> %AgentStatus{}
        existing -> existing
      end

    case Repo.insert_or_update(AgentStatus.changeset(status_record, new_status)) do
      {:ok, _} ->
        Cache.put_agent_status(agent_id, new_status)

      {:error, changeset} ->
        Logger.warning(
          "[Acs] Failed to persist agent status for #{agent_id}: #{inspect(changeset.errors)}"
        )
    end

    new_status
  end

  @doc """
  Clears agent status (removes current_task_id).
  """
  def clear_agent_status(agent_id) do
    case Repo.get(AgentStatus, agent_id) do
      nil ->
        Cache.delete_agent_status(agent_id)

      status ->
        Repo.delete(status)
        Cache.delete_agent_status(agent_id)
    end

    Acs.broadcast(:agent_removed, %{agent_id: agent_id})
    :ok
  end

  @doc """
  Lists organizations from configured external apps via HTTP bridge.
  Returns [] if no apps are configured or unavailable.

  Specify an app name to target a specific app, or omit to try the first configured app.
  """
  def list_orgs(app_name \\ nil) do
    apps = Acs.Apps.Config.list_apps()

    target =
      if app_name do
        apps[app_name]
      else
        apps |> Map.values() |> List.first()
      end

    case target do
      nil ->
        []

      config ->
        base_url = Keyword.get(config, :base_url)
        api_key = Keyword.get(config, :api_key, "")

        if base_url do
          headers = [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"},
            {"accept", "application/json"}
          ]

          case Req.request(
                 method: :post,
                 url: base_url <> "/api/tools/list_orgs",
                 headers: headers,
                 json: %{},
                 receive_timeout: 15_000
               ) do
            {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
              Map.get(body, "orgs", [])

            _ ->
              Logger.warning("[Acs.Acs] list_orgs request failed for app=#{app_name}")
              []
          end
        else
          []
        end
    end
  end

  @doc """
  Gets the current time offset in seconds.
  """
  def get_time_offset do
    Time.get_time_offset()
  end

  @doc """
  Sets the time offset in seconds and persists it.
  """
  def set_time_offset(seconds) when is_integer(seconds) do
    Time.set_time_offset(seconds)
  end

  @doc """
  Returns the current time adjusted by the configured offset.
  """
  def adjusted_now do
    Time.adjusted_now()
  end
end
