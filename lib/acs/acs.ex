defmodule Acs.Acs do
  @moduledoc """
  Agent Coordination System - Core operations module.

  This module provides the main API for task management, file locking,
  and agent coordination. It delegates to Cache for in-memory state
  and Repo for persistent storage.
  """

  alias Acs.Repo
  alias Acs.Acs.Task
  alias Acs.Acs.AgentStatus
  alias Acs.Acs.Cache

  require Logger

  @doc """
  Gets a task by UUID ID or kebab-case slug. Returns the task struct or nil.
  """
  def get_task(task_id) when is_binary(task_id) do
    import Ecto.Query
    org = Acs.Org.current()

    if match?({:ok, _}, Ecto.UUID.cast(task_id)) do
      Repo.one(from t in Task, where: t.id == ^task_id and t.org == ^org)
    else
      Repo.one(from t in Task, where: t.slug == ^task_id and t.org == ^org)
    end
  end

  @doc """
  Lists tasks with optional status filter and org scope.
  """
  def list_tasks(status_filter \\ nil, org \\ nil) do
    org = org || Acs.Org.current()
    import Ecto.Query

    # Default list is coordination work — user reminders use list_tasks(kind: "user").
    query =
      from(t in Task,
        where: t.org == ^org,
        where: t.kind != "user" or is_nil(t.kind),
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
    org = Acs.Org.current()

    new_status =
      Map.merge(
        %{
          agent_id: agent_id,
          current_task_id: nil,
          purpose: nil,
          application: nil,
          component: nil,
          org: org
        },
        attrs
      )
      |> Map.put(:org, org)

    # Get existing record or create new one for insert_or_update
    status_record =
      case Repo.get_by(AgentStatus, agent_id: agent_id, org: org) do
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
    Cache.get_time_offset()
  end

  @doc """
  Sets the time offset in seconds and persists it.
  """
  def set_time_offset(seconds) when is_integer(seconds) do
    Cache.set_time_offset(seconds)
  end
end
