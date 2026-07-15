defmodule Acs do
  @moduledoc """
  Agent Coordination System - task locking, file locking, and present status tracking.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Acs.Repo
  alias Acs.Acs.Task, as: AcsTask
  alias Acs.Acs.FileLock
  alias Acs.Acs.AgentStatus
  alias Acs.Acs.Cache
  alias Acs.Acs.Similarity
  alias Acs.Memory.Guidance
  alias Acs.Org, as: Org

  @doc false
  def broadcast(event, payload) do
    Phoenix.PubSub.broadcast(AcsWeb.PubSub, "acs", {event, payload})
  end

  # ============================================================================
  # Task Operations
  # ============================================================================

  @doc """
  Creates a new task.
  """
  def create_task(attrs, agent_id) when is_binary(agent_id) do
    attrs = normalize_attrs(attrs)
    title = attrs["title"] || ""
    _description = attrs["description"] || ""
    file_paths = attrs["file_paths"] || []

    case check_no_duplicate_title(title) do
      {:error, _} = error ->
        error

      :ok ->
        similar = Similarity.find_similar_tasks(title, file_paths)

        org = Org.current()

        task_attrs =
          attrs
          |> Map.drop(["org", "org_id", "cluster"])
          |> Map.merge(%{
            "created_by_agent" => agent_id,
            "org" => org,
            "status" => Map.get(attrs, "status", "todo")
          })

        task_attrs =
          if task_attrs["status"] == "claimed" do
            Map.put(task_attrs, "locked_by_agent", agent_id)
          else
            task_attrs
          end

        case %AcsTask{} |> AcsTask.changeset(task_attrs) |> Repo.insert() do
          {:ok, task} = result ->
            Cache.put_task(task.id, to_task_map(task))
            broadcast(:task_created, %{task_id: task.id, title: task.title})
            if Enum.any?(similar), do: {:warn, task, similar}, else: result

          error ->
            error
        end
    end
  end

  @doc """
  Updates/bumps a task — increments event_count and optionally updates description.
  Returns `{:ok, updated_task}` or `{:error, reason}`.
  """
  def bump_task(task_id, updates) when is_binary(task_id) do
    case Repo.one(from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())) do
      nil ->
        {:error, :task_not_found}

      task ->
        new_event_count = (task.event_count || 1) + 1
        description = updates["description"] || task.description

        task
        |> AcsTask.changeset(%{
          "event_count" => new_event_count,
          "description" => description
        })
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Cache.put_task(updated.id, to_task_map(updated))
            broadcast(:task_updated, %{task_id: updated.id, event_count: new_event_count})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  Claims a task for an agent.
  """
  def claim_task(task_id, agent_id, opts \\ []) when is_binary(task_id) and is_binary(agent_id) do
    result =
      Repo.transaction(fn ->
        query = from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())
        task = Repo.one(query, lock: "FOR UPDATE")

        case task do
          nil ->
            Repo.rollback({:error, :task_not_found})

          %AcsTask{locked_by_agent: locked_by} when not is_nil(locked_by) ->
            Repo.rollback({:error, :already_locked})

          %AcsTask{} = task ->
            now = DateTime.utc_now()
            auto_release = DateTime.add(now, 10, :minute)

            {:ok, updated} =
              task
              |> AcsTask.changeset(%{
                "locked_by_agent" => agent_id,
                "locked_at" => now,
                "auto_release_at" => auto_release,
                "status" => "in_progress"
              })
              |> Repo.update()

            updated
        end
      end)

    case result do
      {:ok, task} ->
        upsert_agent_status(agent_id, task.id, "Working on task", nil, nil)
        Cache.put_task(task.id, to_task_map(task))
        broadcast(:task_claimed, %{task_id: task.id, agent_id: agent_id})
        broadcast(:agent_updated, %{agent_id: agent_id, status: "working"})

        guidance =
          unless opts[:skip_guidance] do
            Acs.Memory.Guidance.for_task(task.id, tier: :claim)
          end

        {:ok, task, guidance}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Releases a task lock.
  """
  def release_task(task_id, agent_id) when is_binary(task_id) and is_binary(agent_id) do
    result =
      Repo.transaction(fn ->
        query = from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())

        case Repo.one(query, lock: "FOR UPDATE") do
          nil ->
            nil

          %{locked_by_agent: locked_by} when not is_nil(locked_by) and locked_by != agent_id ->
            Repo.rollback({:error, :not_owner})

          %{locked_by_agent: nil} ->
            nil

          %AcsTask{} = task ->
            {:ok, updated} =
              task
              |> AcsTask.changeset(%{
                "locked_by_agent" => nil,
                "locked_at" => nil,
                "auto_release_at" => nil,
                "status" => "done"
              })
              |> Repo.update()

            updated
        end
      end)

    case result do
      {:ok, nil} ->
        {:error, :task_not_claimed}

      {:ok, task} ->
        release_file_locks_for_task(task_id)
        clear_agent_status(agent_id)
        Cache.put_task(task.id, to_task_map(task))
        broadcast(:task_released, %{task_id: task.id, agent_id: agent_id})
        broadcast(:agent_updated, %{agent_id: agent_id, status: "sleeping"})
        {:ok, task}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Updates a task's status.
  """
  def set_task_status(task_id, agent_id, new_status)
      when is_binary(task_id) and is_binary(agent_id) do
    result =
      Repo.transaction(fn ->
        query = from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current())
        task = Repo.one(query, lock: "FOR UPDATE")

        case task do
          nil ->
            Repo.rollback({:error, :task_not_found})

          %AcsTask{locked_by_agent: locked_by}
          when not is_nil(locked_by) and locked_by != agent_id ->
            Repo.rollback({:error, :not_owner})

          %AcsTask{} = task ->
            {:ok, updated} =
              task
              |> AcsTask.changeset(%{"status" => new_status})
              |> Repo.update()

            updated
        end
      end)

    case result do
      {:ok, task} ->
        Cache.put_task(task.id, to_task_map(task))
        broadcast(:task_status_changed, %{task_id: task.id, status: new_status})
        clear_agent_status(agent_id)
        {:ok, task}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all tasks, optionally filtered by status.
  """
  def list_tasks(status_filter \\ nil, org \\ nil) do
    org = org || Org.current()

    query =
      AcsTask
      |> order_by(desc: :inserted_at)
      |> where([t], t.org == ^org)

    query = if status_filter, do: where(query, [t], t.status == ^status_filter), else: query
    Repo.all(query) |> Enum.map(&to_task_map/1)
  end

  @doc """
  Gets a single task by ID.
  """
  def get_task(task_id) when is_binary(task_id) do
    Repo.one(from(t in AcsTask, where: t.id == ^task_id and t.org == ^Org.current()))
  end

  @doc """
  Resets ALL ACS data.
  """
  def reset_all do
    org = Org.current()
    Repo.delete_all(from f in FileLock, where: f.org == ^org)
    Repo.delete_all(from s in AgentStatus, where: s.org == ^org)
    Repo.delete_all(from t in AcsTask, where: t.org == ^org)

    Cache.get_all_tasks(org) |> Enum.each(&Cache.delete_task(&1.id, org))
    Cache.get_all_file_locks(org) |> Enum.each(&Cache.delete_file_lock(&1.file_path, org))
    Cache.get_all_agent_statuses(org) |> Enum.each(&Cache.delete_agent_status(&1.agent_id, org))
    Logger.info("[Acs] ACS data reset for org=#{org}")
    broadcast(:acs_reset, %{})
    :ok
  end

  # ============================================================================
  # File Lock Operations
  # ============================================================================

  @doc """
  Locks a file for an agent.
  """
  def lock_file(file_path, agent_id, task_id)
      when is_binary(file_path) and is_binary(agent_id) and is_binary(task_id) do
    task = get_task(task_id)

    # Idempotent: already locked by this agent for this file = success
    case Repo.get_by(FileLock,
           file_path: file_path,
           locked_by_agent: agent_id,
           org: Org.current()
         ) do
      %FileLock{task_id: ^task_id} ->
        {:ok, %{status: "already_locked", file_path: file_path}}

      %FileLock{} ->
        # Locked by different agent or different task
        {:error, :file_locked_by_other}

      _ ->
        :ok
    end
    |> case do
      {:ok, _} = result ->
        result

      {:error, _} = result ->
        result

      :ok ->
        cond do
          is_nil(task) ->
            {:error, :task_not_found}

          not is_nil(task.locked_by_agent) and task.locked_by_agent != agent_id ->
            {:error, :task_not_locked_by_agent}

          true ->
            now = DateTime.utc_now()
            auto_release = DateTime.add(now, 10, :minute)

            %FileLock{}
            |> FileLock.changeset(%{
              "file_path" => file_path,
              "locked_by_agent" => agent_id,
              "task_id" => task_id,
              "org" => Org.current(),
              "locked_at" => now,
              "auto_release_at" => auto_release
            })
            |> Repo.insert()
            |> case do
              {:ok, lock} ->
                Cache.put_file_lock(file_path, to_file_lock_map(lock))

                broadcast(:file_locked, %{
                  file_path: file_path,
                  agent_id: agent_id,
                  task_id: task_id
                })

                scope_path = scope_from_file_path(file_path)

                guidance =
                  if scope_path != "", do: Guidance.generate(scope_path, tier: :claim), else: %{}

                {:ok, %{status: "locked", file_path: file_path, guidance: guidance}}

              {:error, changeset} ->
                errors = inspect(changeset.errors)

                if String.contains?(errors, "unique_constraint") do
                  {:error, :already_locked}
                else
                  {:error, "Lock failed: #{format_changeset_errors(changeset)}"}
                end
            end
        end
    end
  end

  @doc """
  Unlocks a file.
  """
  def unlock_file(file_path, agent_id) when is_binary(file_path) and is_binary(agent_id) do
    lock = Repo.get_by(FileLock, file_path: file_path, org: Org.current())

    case lock do
      nil ->
        {:error, :not_found}

      %FileLock{locked_by_agent: locked_by} when locked_by != agent_id ->
        {:error, :not_owner}

      %FileLock{} = lock ->
        Repo.delete(lock)
        Cache.delete_file_lock(file_path)
        broadcast(:file_unlocked, %{file_path: file_path})
        :ok
    end
  end

  @doc """
  Unlocks all files for a specific task.
  """
  def unlock_files_for_task(task_id, agent_id) when is_binary(task_id) and is_binary(agent_id) do
    task = get_task(task_id)

    if is_nil(task) or task.locked_by_agent != agent_id do
      {:error, :not_owner}
    else
      org = Org.current()
      locks = Repo.all(from(f in FileLock, where: f.task_id == ^task_id and f.org == ^org))

      Enum.each(locks, fn lock ->
        Repo.delete(lock)
        Cache.delete_file_lock(lock.file_path, org)
      end)

      broadcast(:file_unlocked, %{task_id: task_id})
      :ok
    end
  end

  @doc """
  Gets all currently locked files.
  """
  def get_locked_files(org \\ nil) do
    org = org || Org.current()
    Repo.all(from(f in FileLock, where: f.org == ^org)) |> Enum.map(&to_file_lock_map/1)
  end

  @doc """
  Checks if a specific file is locked.
  """
  def check_file_lock(file_path) do
    {:ok, Repo.get_by(FileLock, file_path: file_path, org: Org.current())}
  end

  # ============================================================================
  # Present Status Operations
  # ============================================================================

  @doc """
  Gets the present status of all agents.
  """
  def get_present_status(_cluster \\ nil) do
    statuses = Acs.Acs.get_present_status()

    task_ids = statuses |> Enum.map(& &1.current_task_id) |> Enum.reject(&is_nil/1)

    org = Org.current()

    tasks_map =
      if task_ids != [] do
        Repo.all(from(t in AcsTask, where: t.id in ^task_ids and t.org == ^org))
        |> Enum.map(&to_task_map/1)
        |> Enum.into(%{}, fn t -> {t.id, t} end)
      else
        %{}
      end

    locks_map =
      if task_ids != [] do
        Repo.all(from(f in FileLock, where: f.task_id in ^task_ids and f.org == ^org))
        |> Enum.group_by(& &1.task_id)
      else
        %{}
      end

    statuses
    |> Enum.map(fn s ->
      task = Map.get(tasks_map, s.current_task_id)
      locks = Map.get(locks_map, s.current_task_id, [])
      locked_files = Enum.map(locks, fn l -> l.file_path end)
      working? = !is_nil(s.current_task_id)

      {s.agent_id,
       %{
         task: task,
         purpose: s.purpose,
         application: s.application,
         component: s.component,
         locked_files: locked_files,
         status: if(working?, do: "working", else: "sleeping")
       }}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Gets the present status of a specific agent.
  """
  def get_agent_present_status(agent_id) do
    status = Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current())

    if status && status.current_task_id do
      task = get_task(status.current_task_id) |> to_task_map()

      locks =
        Repo.all(
          from(f in FileLock,
            where: f.task_id == ^status.current_task_id and f.org == ^Org.current()
          )
        )

      locked_files = Enum.map(locks, fn l -> l.file_path end)

      %{
        task: task,
        purpose: status.purpose,
        application: status.application,
        component: status.component,
        locked_files: locked_files
      }
    else
      nil
    end
  end

  defdelegate find_similar_tasks(title, file_paths), to: Similarity

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_changeset_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  defp scope_from_file_path(file_path) do
    file_path
    |> String.split("/")
    |> Enum.slice(0..-2//1)
    |> Enum.join("/")
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    for {k, v} <- attrs, into: %{}, do: {to_string(k), v}
  end

  defp release_file_locks_for_task(task_id) do
    org = Org.current()
    locks = Repo.all(from(f in FileLock, where: f.task_id == ^task_id and f.org == ^org))

    Enum.each(locks, fn lock ->
      Repo.delete(lock)
      Cache.delete_file_lock(lock.file_path, org)
    end)
  end

  defp upsert_agent_status(agent_id, task_id, purpose, application, component) do
    case Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current()) do
      nil ->
        %AgentStatus{agent_id: agent_id}
        |> AgentStatus.changeset(%{
          "current_task_id" => task_id,
          "purpose" => purpose,
          "application" => application,
          "component" => component,
          "org" => Org.current()
        })
        |> Repo.insert()

      status ->
        status
        |> AgentStatus.changeset(%{
          "current_task_id" => task_id,
          "purpose" => purpose,
          "application" => application,
          "component" => component,
          "org" => Org.current()
        })
        |> Repo.update()
    end
    |> case do
      {:ok, s} -> Cache.put_agent_status(agent_id, to_agent_status_map(s))
      _ -> :ok
    end
  end

  defp clear_agent_status(agent_id) do
    case Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current()) do
      nil ->
        :ok

      status ->
        case Repo.delete(status) do
          {:ok, _} ->
            Cache.delete_agent_status(agent_id)
            :ok

          {:error, _} ->
            Logger.warning(
              "[Acs] Failed to clear agent status for #{agent_id}, still cleaning cache"
            )

            Cache.delete_agent_status(agent_id)
            {:error, :db_delete_failed}
        end
    end
  end

  defp check_no_duplicate_title(title) when is_binary(title) do
    import Ecto.Query
    org = Org.current()

    case Repo.one(
           from(t in Acs.Acs.Task,
             where: fragment("LOWER(?)", t.title) == ^String.downcase(title),
             where: t.status not in ^["done"],
             where: t.org == ^org,
             limit: 1
           )
         ) do
      nil ->
        :ok

      existing ->
        {:error, "A task with the title '#{title}' already exists (status: #{existing.status})"}
    end
  end

  defp to_task_map(%AcsTask{} = t) do
    %{
      id: t.id,
      title: t.title,
      description: t.description,
      status: t.status,
      created_by_agent: t.created_by_agent,
      locked_by_agent: t.locked_by_agent,
      locked_at: t.locked_at,
      auto_release_at: t.auto_release_at,
      inserted_at: t.inserted_at,
      event_count: t.event_count,
      file_paths: t.file_paths || [],
      org: t.org
    }
  end

  defp to_file_lock_map(%FileLock{} = l) do
    %{
      id: l.id,
      file_path: l.file_path,
      locked_by_agent: l.locked_by_agent,
      locked_at: l.locked_at,
      auto_release_at: l.auto_release_at,
      task_id: l.task_id,
      org: l.org
    }
  end

  defp to_agent_status_map(%AgentStatus{} = s) do
    %{
      agent_id: s.agent_id,
      current_task_id: s.current_task_id,
      purpose: s.purpose,
      application: s.application,
      component: s.component,
      org: s.org
    }
  end

  @doc """
  Updates agent application and component context.
  """
  def update_agent_context(agent_id, application, component, purpose \\ nil) do
    case Repo.get_by(AgentStatus, agent_id: agent_id, org: Org.current()) do
      nil ->
        %AgentStatus{agent_id: agent_id}
        |> AgentStatus.changeset(%{
          "application" => application,
          "component" => component,
          "purpose" => purpose,
          "org" => Org.current()
        })
        |> Repo.insert()

      status ->
        status
        |> AgentStatus.changeset(%{
          "application" => application,
          "component" => component,
          "purpose" => purpose || status.purpose,
          "org" => Org.current()
        })
        |> Repo.update()
    end
    |> case do
      {:ok, s} -> Cache.put_agent_status(agent_id, to_agent_status_map(s))
      _ -> :ok
    end
  end
end
